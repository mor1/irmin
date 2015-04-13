(*
 * Copyright (c) 2013-2015 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Irmin.Merge.OP
let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

module Log = Log.Make(struct let section = "HTTP" end)

(* ~uri *)
let uri =
  Irmin.Private.Conf.key
    ~docv:"URI"
    ~doc:"Location of the remote store."
    "uri" Irmin.Private.Conf.(some uri) None

let config x =
  Irmin.Private.Conf.singleton uri (Some x)

let uri_append t path = match Uri.path t :: path with
  | []   -> t
  | path ->
    let buf = Buffer.create 10 in
    List.iter (function
        | "" -> ()
        | s  ->
          if s.[0] <> '/' then Buffer.add_char buf '/';
          Buffer.add_string buf s;
      ) path;
    let path = Buffer.contents buf in
    Uri.with_path t path

let err_no_uri () = invalid_arg "Irmin_http.create: No URI specified"

let get_uri config = match Irmin.Private.Conf.get config uri with
  | None   -> err_no_uri ()
  | Some u -> u

let add_uri_suffix suffix config =
  let v = uri_append (get_uri config) [suffix] in
  Irmin.Private.Conf.add config uri (Some v)

let invalid_arg fmt =
  Printf.ksprintf (fun str -> Lwt.fail (Invalid_argument str)) fmt

let some x = Some x

module Helper (Client: Cohttp_lwt.Client) = struct

  exception Error of string

  let result_of_json json =
    let error =
      try Some (Ezjsonm.find json ["error"])
      with Not_found -> None in
    let result =
      try Some (Ezjsonm.find json ["result"])
      with Not_found -> None in
    match error, result with
    | None  , None   -> raise (Error "result_of_json")
    | Some e, None   -> raise (Error (Ezjsonm.decode_string_exn e))
    | None  , Some r -> r
    | Some _, Some _ -> raise (Error "result_of_json")

  let map_string_response (type t) (module M: Tc.S0 with type t = t) (_, b) =
    Cohttp_lwt_body.to_string b >>= fun b ->
    Log.debug "got response: %s" b;
    let j = Ezjsonm.from_string b in
    try
      Ezjsonm.value j
      |> result_of_json
      |> M.of_json
      |> Lwt.return
    with Error e ->
      Lwt.fail (Error e)

  let map_stream_response (type t) (module M: Tc.S0 with type t = t) (_, b) =
    let stream = Cohttp_lwt_body.to_stream b in
    let stream = Ezjsonm_lwt.from_stream stream in
    let stream = Lwt_stream.map result_of_json stream in
    Lwt_stream.map (fun j ->
        Log.debug "stream: got %s" Ezjsonm.(to_string (wrap j));
        M.of_json j
      ) stream

  let headers = Cohttp.Header.of_list [
      "Connection", "Keep-Alive"
    ]

  let make_uri t path query =
    let uri = uri_append t path in
    match query with
    | None   -> uri
    | Some q -> Uri.with_query uri q

  let map_get t path ?query fn =
    let uri = make_uri t path query in
    Log.debug "get %s" (Uri.path uri);
    Client.get ~headers uri >>= fn

  let get t path ?query fn =
    map_get t path ?query (map_string_response fn)

  let get_stream t path ?query fn  =
    let (stream: 'a Lwt_stream.t option ref) = ref None in
    let rec get () =
      match !stream with
      | Some s -> Lwt_stream.get s
      | None   ->
        map_get t path ?query (fun b ->
            let s = map_stream_response fn b in
            stream := Some s;
            Lwt.return_unit) >>= fun () ->
        get () in
    Lwt_stream.from get

  let delete t path fn =
    let uri = uri_append t path in
    Log.debug "delete %s" (Uri.path uri);
    Client.delete uri >>= map_string_response fn

  let make_body body =
    let body = match body with
      | None   -> None
      | Some b -> Some (Ezjsonm.to_string (`O [ "params", b ]))
    in
    let short_body = match body with
      | None   -> "<none>"
      | Some b -> if String.length b > 80 then String.sub b 0 80 ^ ".." else b
    in
    let body = match body with
      | None   -> None
      | Some b -> Some (Cohttp_lwt_body.of_string b)
    in
    short_body, body

  let map_post t path ?query body fn =
    let uri = make_uri t path query in
    let short_body, body = make_body body in
    Log.debug "post %s %s" (Uri.path uri) short_body;
    Client.post ?body ~headers uri >>= fn

  let post t path ?query body fn =
    map_post t path ?query body (map_string_response fn)

  let post_stream t path ?query ?body fn  =
    let (stream: 'a Lwt_stream.t option ref) = ref None in
    let rec get () =
      match !stream with
      | Some s -> Lwt_stream.get s
      | None   ->
        map_post t path ?query body (fun b ->
            let s = map_stream_response fn b in
            stream := Some s;
            Lwt.return_unit) >>= fun () ->
        get () in
    Lwt_stream.from get

end

module RO (Client: Cohttp_lwt.Client) (K: Irmin.Hum.S) (V: Tc.S0) = struct

  include Helper (Client)

  type t = { mutable uri: Uri.t; task: Irmin.task; }
  type key = K.t
  type value = V.t

  let get t = get t.uri
  let task t = t.task
  let uri t = t.uri

  let create config task =
    let uri = get_uri config in
    Lwt.return (fun a -> { uri; task = task a})

  let read t key = get t ["read"; K.to_hum key] (module Tc.Option(V))

  let mem t key = get t ["mem"; K.to_hum key] Tc.bool

  let err_not_found n k =
    invalid_arg "Irmin_http.%s: %s not found" n (K.to_hum k)

  let read_exn t key =
    read t key >>= function
    | None   -> err_not_found "read" key
    | Some v -> Lwt.return v

  let iter t fn =
    let fn key = fn key (read_exn t key) in
    Lwt_stream.iter_p fn (get_stream t.uri ["iter"] (module K))

end

module AO (Client: Cohttp_lwt.Client) (K: Irmin.Hash.S) (V: Tc.S0) = struct

  include RO (Client)(K)(V)

  let post t = post t.uri

  let add t value = post t ["add"] (some @@ V.to_json value) (module K)

end

module RW (Client: Cohttp_lwt.Client) (K: Irmin.Hum.S) (V: Tc.S0) = struct

  module RO = RO (Client)(K)(V)
  module W  = Irmin.Private.Watch.Make(K)(V)

  type key = RO.key
  type value = RO.value
  type watch = W.watch

  (* cache the stream connections to the server: we open only one
     connection per stream kind. *)
  type cache = { mutable worker: unit Lwt.t; }

  let empty_cache () = { worker = Lwt.return_unit; }

  type t = { t: RO.t; w: W.t; keys: cache; glob: cache }

  let post t = RO.post (RO.uri t.t)
  let delete t = RO.delete (RO.uri t.t)
  let post_stream t = RO.post_stream (RO.uri t.t)

  let create config task =
    RO.create config task >>= fun t ->
    let w = W.create () in
    let keys = empty_cache () in
    let glob = empty_cache () in
    Lwt.return (fun a -> { t = t a; w; keys; glob })

  let uri t = RO.uri t.t
  let task t = RO.task t.t
  let read t = RO.read t.t
  let read_exn t = RO.read_exn t.t
  let mem t = RO.mem t.t
  let iter t = RO.iter t.t

  let update t key value =
    post t ["update"; K.to_hum key] (some @@ V.to_json value) Tc.unit

  let remove t key = delete t ["remove"; K.to_hum key] Tc.unit

  module CS = Tc.Pair(Tc.Option(V))(Tc.Option(V))

  let compare_and_set t key ~test ~set =
    post t ["compare-and-set"; K.to_hum key] (some @@ CS.to_json (test, set))
      Tc.bool

  let nb_keys t = fst (W.stats t.w)
  let nb_glob t = snd (W.stats t.w)

  module OV = Tc.Option (V)

let with_cancel t =
  Lwt.catch t (function Lwt.Canceled -> Lwt.return_unit | e -> Lwt.fail e)

let watch_key t key ?init f =
    if nb_keys t = 0 then (
      let body = OV.to_json init in
      let s = post_stream t ~body ["watch-key"] (module OV) in
      let worker = Lwt_stream.iter_s (W.notify t.w key) s in
      t.keys.worker <- worker;
      Lwt.async (fun () -> with_cancel (fun () -> worker))
    );
    W.watch_key t.w key ?init f

  module WI = Tc.Option (Tc.List (Tc.Pair (K) (V)))
  module WS = Tc.Pair (K) (Tc.Option (V))

  let watch t ?init f =
    if nb_glob t  = 0 then (
      let body = WI.to_json init in
      let s = post_stream t ~body ["watch"] (module WS) in
      let worker = Lwt_stream.iter_s (fun (k, v) -> W.notify t.w k v) s in
      t.glob.worker <- worker;
      Lwt.async (fun () -> with_cancel (fun () -> worker));
    );
    W.watch t.w ?init f

  let unwatch t id =
    W.unwatch t.w id >>= fun () ->
    if nb_keys t = 0 then Lwt.cancel t.keys.worker;
    if nb_glob t = 0 then Lwt.cancel t.glob.worker;
    Lwt.return_unit

end

module Low (Client: Cohttp_lwt.Client)
    (C: Irmin.Contents.S)
    (T: Irmin.Tag.S)
    (H: Irmin.Hash.S) =
struct
  module X = struct
    module Contents = Irmin.Contents.Make(struct
        module Key = H
        module Val = C
        include AO(Client)(H)(C)
        let create config task = create (add_uri_suffix "contents" config) task
      end)
    module Node = struct
      module Key = H
      module Path = C.Path
      module Val = Irmin.Private.Node.Make(H)(H)(C.Path)
      include AO(Client)(Key)(Val)
      let create config task = create (add_uri_suffix "node" config) task
    end
    module Commit = struct
      module Key = H
      module Val = Irmin.Private.Commit.Make(H)(H)
      include AO(Client)(Key)(Val)
      let create config task = create (add_uri_suffix "commit" config) task
    end
    module Tag = struct
      module Key = T
      module Val = H
      include RW(Client)(Key)(Val)
      let create config task = create (add_uri_suffix "tag" config) task
    end
    module Slice = Irmin.Private.Slice.Make(Contents)(Node)(Commit)
    module Sync = Irmin.Private.Sync.None(H)(T)
  end
  include Irmin.Make_ext(X)
end

module Make (Client: Cohttp_lwt.Client)
    (C: Irmin.Contents.S)
    (T: Irmin.Tag.S)
    (H: Irmin.Hash.S) =
struct

  module T = struct
    include T
    let to_hum t = Uri.pct_encode (to_hum t)
    let of_hum t = of_hum (Uri.pct_decode t)
  end

  module P = struct

    include C.Path

    let to_hum t =
      String.concat "/" (C.Path.map t (fun x -> Uri.pct_encode (Step.to_hum x)))

    let of_hum t =
      List.filter ((<>)"") (Stringext.split t ~on:'/')
      |> List.map (fun x -> Step.of_hum (Uri.pct_decode x))
      |> C.Path.create

  end

  include Helper (Client)

  (* Implementing a high-level HTTP BC backend is a bit tricky as we
     need to keep track of some hidden state which is not directly
     exposed by the interface. This is the case when we are in
     `detached` mode, and an high-level update does not return the new
     head value.

     We solve this by tapping updating the HTTP API to return more
     information than the OCaml API dictates. in lower-level
     bindings. *)

  (* The high-level bindings: every high-level operation is simply
     forwarded to the HTTP server. *much* more efficient than using
     [L]. *)
  module L = Low(Client)(C)(T)(H)
  module LP = L.Private
  module S  = RW(Client)(P)(C)

  (* [t.s.uri] always point to the right location:
       - `$uri/` if branch = `Tag T.master
       - `$uri/tree/$tag` if branch = `Tag tag
       - `$uri/tree/$key if key = `Key key *)
  type t = {
    branch: [`Tag of T.t | `Head of H.t | `Empty] ref;
    mutable h: S.t; l: L.t;
    config: Irmin.config;
    contents_t: LP.Contents.t;
    node_t: LP.Node.t;
    commit_t: LP.Commit.t;
    tag_t: LP.Tag.t;
    read_node: L.key -> LP.Node.key option Lwt.t;
    mem_node: L.key -> bool Lwt.t;
    update_node: L.key -> LP.Node.key -> unit Lwt.t;
    lock: Lwt_mutex.t;
  }

  let branch t = !(t.branch)

  let uri t =
    let base = S.uri t.h in
    match branch t with
    | `Tag tag ->
      if T.equal tag T.master then base
      else uri_append base ["tree"; T.to_hum tag]
    | `Empty  -> failwith "TODO"
    | `Head h -> uri_append base ["tree"; H.to_hum h]

  let task t = S.task t.h
  let set_tag t tag = t.branch := `Tag tag
  let set_head t = function
    | None   -> t.branch := `Empty
    | Some h -> t.branch := `Head h

  type key = S.key
  type value = S.value
  type head = L.head
  type tag = L.tag

  let create_aux branch config h l =
    let fn a =
      let h = h a in
      let l = l a in
      let contents_t = LP.contents_t l in
      let node_t = LP.node_t l in
      let commit_t = LP.commit_t l in
      let tag_t = LP.tag_t l in
      let read_node = LP.read_node l in
      let mem_node = LP.mem_node l in
      let update_node = LP.update_node l in
      let lock = Lwt_mutex.create () in
      { l; branch; h; contents_t; node_t; commit_t; tag_t;
        read_node; mem_node; update_node; config;
        lock; }
    in
    Lwt.return fn

  let create config task =
    S.create config task >>= fun h ->
    L.create config task >>= fun l ->
    let branch = ref (`Tag T.master) in
    create_aux branch config h l

  let of_tag config task tag =
    S.create config task >>= fun h ->
    L.of_tag config task tag >>= fun l ->
    let branch = ref (`Tag tag) in
    create_aux branch config h l

  let of_head config task head =
    S.create config task >>= fun h ->
    L.of_head config task head >>= fun l ->
    let branch = ref (`Head head) in
    create_aux branch config h l

  let empty config task =
    S.create config task >>= fun h ->
    L.empty config task  >>= fun l ->
    let branch = ref `Empty in
    create_aux branch config h l

  let err_not_found n k =
    invalid_arg "Irmin_http.%s: %s not found" n (P.to_hum k)

  let err_no_head = invalid_arg "Irmin_http.%s: no head"
  let err_not_persistent = invalid_arg "Irmin_http.%s: not a persistent branch"

  let get t = get (uri t)
  let post t = post (uri t)
  let delete t = delete (uri t)

  let read t key = get t ["read"; P.to_hum key] (module Tc.Option(C))
  let mem t key = get t ["mem"; P.to_hum key] Tc.bool

  let read_exn t key =
    read t key >>= function
    | None   -> err_not_found "read" key
    | Some v -> Lwt.return v

  (* The server sends a stream of keys *)
  let iter t fn =
    let fn key = fn key (read_exn t key) in
    Lwt_stream.iter_p fn (get_stream (uri t) ["iter"] (module P))

  let update t key value =
    post t ["update"; P.to_hum key] (some @@ C.to_json value) (module H)
    >>= fun h ->
    let () = match branch t with
      | `Empty
      | `Head _ -> set_head t (Some h)
      | `Tag  _ -> ()
    in
    Lwt.return_unit

  let remove t key =
    delete t ["remove"; P.to_hum key] (module H) >>= fun h ->
    let () = match branch t with
      | `Empty
      | `Head _ -> set_head t (Some h)
      | `Tag _  -> ()
    in
    Lwt.return_unit

  module CS = Tc.Pair(Tc.Option(C))(Tc.Option(C))

  let compare_and_set t key ~test ~set =
    post t ["compare-and-set"; P.to_hum key] (some @@ CS.to_json (test, set))
      Tc.bool

  let tag t = match branch t with
    | `Empty
    | `Head _ -> Lwt.return_none
    | `Tag t  -> Lwt.return (Some t)

  let tag_exn t = tag t >>= function
    | None   -> err_not_persistent "tag"
    | Some t -> Lwt.return t

  let tags t = get t ["tags"] (module Tc.List(T))

  let head t = match branch t with
    | `Empty  -> Lwt.return_none
    | `Head h -> Lwt.return (Some h)
    | `Tag _  -> get t ["head"] (module Tc.Option(H))

  let head_exn t =
    head t >>= function
    | None   -> err_no_head "head"
    | Some h -> Lwt.return h

  let update_tag t tag =
    post t ["update-tag"; T.to_hum tag] None Tc.unit >>= fun () ->
    set_tag t tag;
    Lwt.return_unit

  let remove_tag t tag = delete t ["remove-tag"; T.to_hum tag] Tc.unit

  let heads t = get t ["heads"] (module Tc.List(H))

  let update_head t head = match branch t with
    | `Empty
    | `Head _ -> set_head t (Some head); Lwt.return_unit
    | `Tag _  -> get t ["update-head"; H.to_hum head] Tc.unit

  module CSH = Tc.Pair(Tc.Option(H))(Tc.Option(H))

  let compare_and_set_head_unsafe t ~test ~set = match branch t with
    | `Tag _  ->
      post t ["compare-and-set-head"] (some @@ CSH.to_json (test, set)) Tc.bool
    | `Empty ->
      if None = test then (set_head t set; Lwt.return true) else Lwt.return false
    | `Head h ->
      if Some h = test then (set_head t set; Lwt.return true)
      else Lwt.return false

  let compare_and_set_head t ~test ~set =
    Lwt_mutex.with_lock t.lock (fun () ->
        compare_and_set_head_unsafe t ~test ~set
      )

  module M = Tc.App1 (Irmin.Merge.Result) (H)

  let mk_query ?max_depth ?n () =
    let max_depth = match max_depth with
      | None   -> []
      | Some i -> ["depth", [string_of_int i]]
    in
    let n = match n with
      | None   -> []
      | Some i -> ["n", [string_of_int i]]
    in
    match max_depth @ n with
    | [] -> None
    | q  -> Some q

  let fast_forward_head_unsafe t ?max_depth ?n head =
    let query = mk_query ?max_depth ?n () in
    post t ?query ["fast-forward-head"; H.to_hum head] None Tc.bool >>= fun b ->
    match branch t with
    | `Tag _  -> Lwt.return b
    | `Empty
    | `Head _ -> if b then set_head t (Some head); Lwt.return b

  let fast_forward_head t ?max_depth ?n head =
    Lwt_mutex.with_lock t.lock (fun () ->
        fast_forward_head_unsafe t ?max_depth ?n head
      )

  let merge_head t ?max_depth ?n head =
    let query = mk_query ?max_depth ?n () in
    post t ?query ["merge-head"; H.to_hum head] None (module M) >>| fun h ->
    match branch t with
    | `Empty
    | `Head _ -> set_head t (Some h); ok ()
    | `Tag _  -> ok ()

  let merge_head_exn t ?max_depth ?n head =
    merge_head t ?max_depth ?n head >>= Irmin.Merge.exn

  let watch_head t = L.watch_head t.l
  let watch_tags t = L.watch_tags t.l

  let clone task t tag =
    post t ["clone"; T.to_hum tag] None Tc.string >>= function
    | "ok" -> of_tag t.config task tag >|= fun t -> `Ok t
    | _    -> Lwt.return `Duplicated_tag

  let clone_force task t tag =
    post t ["clone-force"; T.to_hum tag] None Tc.unit >>= fun () ->
    of_tag t.config task tag

  let merge_tag t ?max_depth ?n tag =
    let query = mk_query ?max_depth ?n () in
    post t ?query ["merge-tag"; T.to_hum tag] None (module M) >>| fun h ->
    match branch t with
    | `Empty
    | `Head _ -> set_head t (Some h); ok ()
    | `Tag _  -> ok ()

  let merge_tag_exn t ?max_depth ?n tag =
    merge_tag t ?max_depth ?n tag >>= Irmin.Merge.exn

  let merge a ?max_depth ?n t ~into =
    let t = t a and into = into a in
    match branch t with
    | `Tag tag -> merge_tag into ?max_depth ?n tag
    | `Head h  -> merge_head into ?max_depth ?n h
    | `Empty   -> ok ()

  let merge_exn a ?max_depth ?n t ~into =
    merge a ?max_depth ?n t ~into >>= Irmin.Merge.exn

  module LCA = struct
    module HL = Tc.List(H)
    type t = [`Ok of H.t list | `Max_depth_reached | `Too_many_lcas]
    let hash = Hashtbl.hash
    let compare = Pervasives.compare
    let equal = (=)
    let of_json = function
      | `O [ "ok", j ] -> `Ok (HL.of_json j)
      | `A [`String "max-depth-reached" ] -> `Max_depth_reached
      | `A [`String "too-many-lcas"] -> `Too_many_lcas
      | j -> Ezjsonm.parse_error j "LCA.of_json"
    let to_json _ = failwith "TODO"
    let read _ = failwith "TODO"
    let write _ = failwith "TODO"
    let size_of _ = failwith "TODO"
  end

  let lcas_tag t ?max_depth ?n tag =
    let query = mk_query ?max_depth ?n () in
    get t ?query ["lcas-tag"; T.to_hum tag] (module LCA)

  let lcas_head t ?max_depth ?n head =
    let query = mk_query ?max_depth ?n () in
    get t ?query ["lcas-head"; H.to_hum head] (module LCA)

  let lcas a ?max_depth ?n t1 t2 =
    match branch (t2 a) with
    | `Tag tag   -> lcas_tag  (t1 a) ?max_depth ?n tag
    | `Head head -> lcas_head (t1 a) ?max_depth ?n head
    | `Empty     -> Lwt.return (`Ok [])

  let task_of_head t head =
    LP.Commit.read_exn t.commit_t head >>= fun commit ->
    Lwt.return (LP.Commit.Val.task commit)

  module E = Tc.Pair (Tc.List(H)) (Tc.List(H))

  type slice = L.slice

  module Slice = L.Private.Slice

  let export ?full ?depth ?(min=[]) ?(max=[]) t =
    let query =
      let full = match full with
        | None   -> []
        | Some x -> ["full", [string_of_bool x]]
      in
      let depth = match depth with
        | None   -> []
        | Some x -> ["depth", [string_of_int x]]
      in
      match full @ depth with [] -> None | l -> Some l
    in
    (* FIXME: this should be a GET *)
    post t ?query ["export"] (some @@ E.to_json (min, max))
      (module L.Private.Slice)

  module I = Tc.List(T)

  let import t slice =
    post t ["import"] (some @@ Slice.to_json slice) Tc.unit

  let remove_rec t dir =
    delete t ["remove-rec"; P.to_hum dir] (module H) >>= fun h ->
    let () = match branch t with
      | `Empty
      | `Head _ -> set_head t (Some h)
      | `Tag _  -> ()
    in
    Lwt.return_unit

  let list t dir =
    get t ["list"; P.to_hum dir] (module Tc.List(P))

  module History = Graph.Persistent.Digraph.ConcreteBidirectional(H)
  module G = Tc.Pair (Tc.List (H))(Tc.List (Tc.Pair(H)(H)))
  module Conv = struct
    type t = History.t
    let to_t (vertices, edges) =
      let t = History.empty in
      let t = List.fold_left History.add_vertex t vertices in
      List.fold_left (fun t (x, y) -> History.add_edge t x y) t edges
    let of_t t =
      let vertices = History.fold_vertex (fun v l -> v :: l) t [] in
      let edges = History.fold_edges (fun x y l -> (x, y) :: l) t [] in
      vertices, edges
  end
  module HTC = Tc.Biject (G)(Conv)
  module EO = Tc.Pair (Tc.Option(Tc.List(H))) (Tc.Option(Tc.List(H)))

  let history ?depth ?min ?max t =
    let query =
      let depth = match depth with
        | None   -> []
        | Some x -> ["depth", [string_of_int x]]
      in
      match depth with [] -> None | l -> Some l
    in
    (* FIXME: this should be a GET *)
    post t ?query ["history"] (some @@ EO.to_json (min, max)) (module HTC)

  module Key = P
  module Val = C
  module Tag = T
  module Head = H
  module Private = struct
    include L.Private
    let config t = t.config
    let contents_t t = t.contents_t
    let node_t t = t.node_t
    let commit_t t = t.commit_t
    let tag_t t = t.tag_t
    let update_node t = t.update_node
    let read_node t = t.read_node
    let mem_node t = t.mem_node
  end
end
