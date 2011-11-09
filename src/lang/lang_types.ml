(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2011 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

let debug =
  try
    ignore (Sys.getenv "LIQUIDSOAP_DEBUG_LANG") ;
    true
  with
    | Not_found -> false

(* Type information comes attached to the AST from the parsing,
 * with appropriate sharing of the type variables. Then the type inference
 * performs in-place unification.
 *
 * In order to report precise type error messages, we put very dense
 * parsing location information in the type. Every layer of it can have
 * a location. Destructive unification introduces links in such a way
 * that the old location is still accessible.
 *
 * The level annotation represents the number of abstractions which surround
 * the type in the AST -- function arguments and let-in definitions.
 * It is used to safely generalize types.
 *
 * Finally, constraints can be attached to existential (unknown, '_a)
 * and universal ('a) type variables. *)

(** Positions *)

type pos = (Lexing.position*Lexing.position)

let print_single_pos l =
  let file =
    if l.Lexing.pos_fname="" then "" else
      Printf.sprintf "file %s, " l.Lexing.pos_fname
  in
  let line,col = l.Lexing.pos_lnum, (l.Lexing.pos_cnum-l.Lexing.pos_bol) in
    Printf.sprintf "%sline %d, character %d" file line (col+1)

let print_pos ?(prefix="At ") (start,stop) =
  let prefix =
    match start.Lexing.pos_fname with
      | "" -> prefix
      | file -> prefix ^ file ^ ", "
  in
  let f l = l.Lexing.pos_lnum, (l.Lexing.pos_cnum-l.Lexing.pos_bol) in
  let lstart,cstart = f start in
  let lstop,cstop = f stop in
  let cstart = 1+cstart in
    if lstart = lstop then
      if cstart = cstop then
        Printf.sprintf "%sline %d, char %d" prefix lstart cstart
      else
        Printf.sprintf "%sline %d, char %d-%d" prefix lstart cstart cstop
    else
      Printf.sprintf "%sline %d char %d - line %d char %d"
        prefix lstart cstart lstop cstop

(** Ground types *)

type mul = Frame.multiplicity
type ground = Unit | Bool | Int | String | Float

let rec print_ground = function
  | Unit    -> "unit"
  | String  -> "string"
  | Bool    -> "bool"
  | Int     -> "int"
  | Float   -> "float"

(** Type constraints *)

type constr = Num | Ord | Getter of ground | Dtools | Arity_fixed | Arity_any
type constraints = constr list

let print_symconstr = function
  | Arity_any -> Some "*"
  | Arity_fixed -> Some "#"
  | _ -> None

let print_constr = function
  | Num -> "a number type"
  | Ord -> "an orderable type"
  | Getter t ->
      let t = print_ground t in
        Printf.sprintf "either %s or ()->%s" t t
  | Dtools -> "bool, int, float, string or [string]"
  | Arity_any -> "an arity"
  | Arity_fixed -> "a fixed arity"

(** Types *)

type variance = Covariant | Contravariant | Invariant

(** Every type gets a level annotation.
  * This is useful in order to know what can or cannot be generalized:
  * you need to compare the level of an abstraction and those of a ref or
  * source. *)
type t = { pos : pos option ;
           mutable level : int ;
           mutable descr : descr }
and constructed = { name : string ; params : (variance*t) list }
and descr =
  | Constr  of constructed
  | Ground  of ground
  | List    of t
  | Product of t * t
  | Zero | Succ of t | Variable
  | Arrow     of (bool*string*t) list * t
  | EVar      of cvar (* type variable *)
  | Link      of t
  | Record    of record
(* The second member is an optional row variable, which is either an evar or a
   Record. *)
and record = (string * scheme) list * t option
(* A constrained variables *)
and cvar = int * constraints
and scheme = cvar list * t

type repr = [
  | `Constr  of string * (variance*repr) list
  | `Ground  of ground
  | `List    of repr
  | `Product of repr * repr
  | `Zero | `Succ of repr | `Variable
  | `Arrow     of (bool*string*repr) list * repr
  | `EVar      of string*constraints (* existential variable *)
  | `UVar      of string*constraints (* universal variable *)
  | `Record of (string*(string list*repr)) list * repr option
  | `Ellipsis       (* omitted sub-term *)
  | `Range_Ellipsis (* omitted sub-terms (in a list, e.g. list of args) *)
]

let make ?(pos=None) ?(level=(-1)) d =
  { pos = pos ; level = level ; descr = d }

let dummy = make ~pos:None (EVar (-1,[]))

let is_evar t =
  match t.descr with
    | EVar _ -> true
    | _ -> false

(** Merge a record with other records its row variables are pointing to. *)
let rec merge_record r =
  match r with
  | _, None -> r
  | _, Some { descr = EVar _ } -> r
  | r1, Some { descr = Link t } ->
    let r2 =
      match t.descr with
        | Record r -> r
        | _ -> assert false
    in
    let r2, row = merge_record r2 in
    let r2 = List.fold_left (fun r2 (x,_) -> List.remove_assoc x r2) r2 r1 in
    r1@r2, row
  | _ -> assert false

(** Dereferencing gives you the meaning of a term,
  * going through links created by instantiations.
  * One should (almost) never work on a non-dereferenced type. *)
let rec deref t = match t.descr with
  | Link x -> deref x
  | Record r -> { t with descr = Record (merge_record r) }
  | _ -> t

(** Given a strictly positive integer, generate a name in [a-z]+:
    * a, b, ... z, aa, ab, ... az, ba, ... *)
let name =
  let base = 26 in
  let c i = char_of_int (int_of_char 'a' + i - 1) in
  let add i suffix = Printf.sprintf "%c%s" (c i) suffix in
  let rec n suffix i =
    if i<=base then add i suffix else
      let head = i mod base in
      let head = if head = 0 then base else head in
        n (add head suffix) ((i-head)/base)
  in
    n ""

(** Compute the structure that a term [repr]esents,
  * given the list of universally quantified variables.
  * Also takes care of computing the printing name of variables,
  * including constraint symbols, which are removed from constraint lists.
  * It supports a mechanism for filtering out parts of the type,
  * which are then translated as `Ellipsis. *)
let repr ?(filter_out=fun _->false) ?(generalized=[]) t : repr =
  let split_constr c =
    List.fold_left
      (fun (s,constraints) c ->
         match print_symconstr c with
           | None -> s,c::constraints
           | Some sym -> s^sym,constraints)
      ("",[]) c
  in
  let counter = let c = ref 0 in fun () -> incr c ; !c in
  let evars = Hashtbl.create 10 in
  let evar i c =
    let constr_symbols,c = split_constr c in
      if debug then
        `EVar (Printf.sprintf "?%s%d" constr_symbols i, c)
      else
        let s =
          try
            Hashtbl.find evars i
          with Not_found ->
            let name = String.uppercase (name (counter ())) in
              Hashtbl.add evars i name ;
              name
        in
        (* TODO: for debugging, remove this *)
        let s = Printf.sprintf "%s(%d)" s i in
          `EVar (Printf.sprintf "?%s%s" constr_symbols s, c)
  in
  let rec repr ~generalized t =
    let repr ?(generalized=generalized) t = repr ~generalized t in
    let uvar_name ?(generalized=generalized) i c =
      let constr_symbols,c = split_constr c in
      let rec index n = function
        | v::tl ->
          if fst v = i then
            Printf.sprintf "'%s%s" constr_symbols (name n)
          else
            index (n+1) tl
        | [] -> assert false
      in
      index 1 (List.rev generalized)
    in
    let uvar i c =
      `UVar (uvar_name i c, c)
    in
    let is_generalized i = List.exists (fun (j,_) -> j=i) generalized in
    if filter_out t then `Ellipsis else
      match t.descr with
        | Ground g -> `Ground g
        | List t -> `List (repr t)
        | Product (a,b) -> `Product (repr a, repr b)
        | Zero -> `Zero
        | Variable -> `Variable
        | Succ t -> `Succ (repr t)
        | Constr { name=name; params=params } ->
            `Constr (name,
                     List.map (fun (l,t) -> l, repr t) params)
        | Arrow (args,t) ->
            `Arrow (List.map (fun (opt,lbl,t) -> opt,lbl,repr t) args,
                    repr t)
        | EVar (id,c) ->
            if is_generalized id then
              uvar id c
            else
              evar id c
        | Link t -> repr t
        | Record r ->
          let r, row = merge_record r in
          let row =
            match row with
              | Some row -> Some (repr row)
              | None -> None
          in
          `Record
            (List.map
               (fun (x,(g,t)) ->
                 let generalized = g@generalized in
                 let r = repr ~generalized t in
                 x, (List.rev (List.map (fun (i,c) -> uvar_name ~generalized i c) g),r))
               r, row)
  in
    repr ~generalized t

(** Sets of type descriptions. *)
module DS =
  Set.Make(struct type t = (string*constraints) let compare = compare end)

(** Print a type representation.
  * Unless in debug mode, variable identifiers are not shown,
  * and variable names are generated.
  * Names are only meaningful over one printing, as they are re-used. *)
let print_repr f t =
  (** Display the type and return the list of variables that occur in it.
    * The [par] params tells whether (..)->.. should be surrounded by
    * parenthesis or not. *)
  let rec print ~par vars : repr -> DS.t = function
    | `Constr (name,params) ->
        (* Let's assume that stream_kind occurs only inside a source
         * or format type -- this should be pretty much true with the
         * current API -- and simplify the printing by labeling its
         * parameters and omitting the stream_kind(...) to avoid
         * source(stream_kind(2,0,0)). *)
        if name = "stream_kind" then
          match params with
            | [_,a;_,v;_,m] ->
                let first,has_ellipsis,vars =
                  List.fold_left
                    (fun (first,has_ellipsis,vars) (lbl,t) ->
                       if t=`Ellipsis then false,true,vars else begin
                         if not first then Format.fprintf f "," ;
                         Format.fprintf f "%s=" lbl ;
                         let vars = print ~par:false vars t in
                           false,has_ellipsis,vars
                       end)
                    (true,false,vars)
                    ["audio",a;"video",v;"midi",m]
                in
                  if not has_ellipsis then vars else begin
                    if not first then Format.fprintf f ",@," ;
                    print ~par:false vars `Range_Ellipsis
                  end
            | _ -> assert false
        else begin
          Format.open_box (1 + String.length name) ;
          Format.fprintf f "%s(" name ;
          let vars = print_list vars params in
            Format.fprintf f ")" ;
            Format.close_box () ;
            vars
        end
    | `Ground g -> Format.fprintf f "%s" (print_ground g) ; vars
    | `Product (a,b) ->
        Format.fprintf f "@[<1>(" ;
        let vars = print ~par:true vars a in
        Format.fprintf f "*@," ;
        let vars = print ~par:true vars b in
        Format.fprintf f ")@]" ;
        vars
    | `List t ->
        Format.fprintf f "@[<1>[" ;
        let vars = print ~par:false vars t in
        Format.fprintf f "]@]" ;
        vars
    | `Record (r, row) ->
      Format.fprintf f "@[<1>[";
      let _,vars =
        List.fold_left
          (fun (first,vars) (lbl,(g,kind)) ->
            if not first then Format.fprintf f ", @," ;
            let g = if g = [] then "" else ("∀" ^ String.concat " " g ^ " . ") in
            Format.fprintf f "%s: %s" lbl g;
            let vars = print ~par:true vars kind in
            false, vars)
          (true,vars)
          r
      in
      let vars =
        match row with
          | Some row ->
            Format.fprintf f ", @,";
            print ~par vars row
          | None -> vars
      in
      Format.fprintf f "]@]";
      vars
    | `Variable ->
        Format.fprintf f "*" ;
        vars
    | `Zero | `Succ _ as t ->
        let rec aux n = function
          | `Succ t -> aux (n+1) t
          | `Zero -> Format.fprintf f "%d" n ; vars
          | t ->
              if t = `Ellipsis then begin
                Format.fprintf f "%d+" n ;
                print ~par vars t
              end else
                let vars = print ~par vars t in
                  Format.fprintf f "+%d" n ;
                  vars
        in
          aux 0 t
    | `EVar (name,c) | `UVar (name,c) ->
        Format.fprintf f "%s" name ;
        if c<>[] then DS.add (name,c) vars else vars
    | `Arrow (p,t) ->
        if par then
          Format.fprintf f "@[<hov 1>("
        else
          Format.fprintf f "@[<hov 0>" ;
        Format.fprintf f "@[<1>(" ;
        let _,vars =
          List.fold_left
            (fun (first,vars) (opt,lbl,kind) ->
               if not first then Format.fprintf f ",@," ;
               if opt then Format.fprintf f "?" ;
               if lbl <> "" then Format.fprintf f "%s:" lbl ;
               let vars = print ~par:true vars kind in
                 false, vars)
            (true,vars)
            p
        in
        Format.fprintf f ")@]->@," ;
        let vars = print ~par:false vars t in
        if par then Format.fprintf f ")@]" else Format.fprintf f "@]" ;
        vars
    | `Ellipsis -> Format.fprintf f "_" ; vars
    | `Range_Ellipsis -> Format.fprintf f "..." ; vars
  and print_list ?(first=true) ?(acc=[]) vars = function
    | [] -> vars
    | (_,x)::l ->
        if not first then Format.fprintf f "," ;
        let vars = print ~par:false vars x in
          print_list ~first:false ~acc:(x::acc) vars l
  in
    Format.fprintf f "@[" ;
    begin match t with
      (* We're only printing a variable: ignore its [repr]esentation. *)
      | `EVar (i,c) when c <> [] ->
          Format.fprintf f "something that is %s"
            (String.concat " and " (List.map print_constr c))
      | `UVar (i,c) when c <> [] ->
          Format.fprintf f "anything that is %s"
            (String.concat " and " (List.map print_constr c))
      (* Print the full thing, then display constraints *)
      | _ ->
          let constraints = print ~par:false DS.empty t in
          let constraints = DS.elements constraints in
            if constraints <> [] then
              let constraints =
                List.map
                  (fun (name,c) ->
                     name,
                     String.concat " and " (List.map print_constr c))
                  constraints
              in
              let constraints =
                List.stable_sort (fun (_,a) (_,b) -> compare a b) constraints
              in
              let group : ('a*'b) list -> ('a list * 'b) list = function
                | [] -> []
                | (i,c)::l ->
                    let rec group prev acc = function
                      | [] -> [List.rev acc,prev]
                      | (i,c)::l ->
                          if prev = c then group c (i::acc) l else
                            (List.rev acc, prev) :: group c [i] l
                    in
                      group c [i] l
              in
              let constraints = group constraints in
              let constraints =
                List.map
                  (fun (ids,c) -> (String.concat ", " ids) ^ " is " ^ c)
                  constraints
              in
                Format.fprintf f "@ @[<2>where@ " ;
                Format.fprintf f "%s" (List.hd constraints) ;
                List.iter
                  (fun s -> Format.fprintf f ",@ %s" s)
                  (List.tl constraints) ;
                Format.fprintf f "@]"
    end ;
    Format.fprintf f "@]"

let fresh_evar =
  let fresh_id =
    let c = ref 0 in
      fun () -> incr c ; !c
  in
  let f ~constraints ~level ~pos =
    { pos = pos ; level = level ; descr = EVar (fresh_id (),constraints) }
  in
    f

let record ?(level=(-1)) ~row l =
  let row = if row then Some (fresh_evar ~level ~constraints:[] ~pos:None) else None in
  make ~level (Record (l, row))

(** {1 Assignation} *)

(** These two exceptions can be raised when attempting to assign a variable. *)
exception Occur_check of t*t
exception Unsatisfied_constraint of constr*t

(** Check that [a] (a dereferenced type variable) does not occur in [b],
  * and prepare the instantiation [a<-b] by adjusting the levels. *)
let rec occur_check a b =
  let b = deref b in
    if a == b then raise (Occur_check (a,b)) ;
    match b.descr with
      | Constr c -> List.iter (fun (_,x) -> occur_check a x) c.params
      | Product (t1,t2) -> occur_check a t1 ; occur_check a t2
      | List t -> occur_check a t
      | Succ t -> occur_check a t
      | Zero | Variable -> ()
      | Arrow (p,t) ->
          List.iter
            (fun (o,l,t) -> occur_check a t)
            p ;
          occur_check a t
      | EVar _ ->
          (* In normal type inference level -1 should never arise.
           * Unfortunately we can't check it strictly because this code
           * is also used to process type annotations, which make use
           * of unknown levels. Also note that >=0 levels can arise
           * when processing type annotations, because of builtins. *)
          if b.level = -1 then
            b.level <- a.level
          else if a.level <> -1 then
            b.level <- min b.level a.level
      | Ground _ -> ()
      | Link _ -> assert false
      | Record r ->
        (* We should not have to check occurences in row variables. *)
        let r, _ = merge_record r in
        List.iter (fun (_,(g,t)) -> occur_check a t) r

(* Perform [a := b] where [a] is an EVar, check that [type(a)<:type(b)]. *)
let rec bind a0 b =
  let a = deref a0 in
  let b = deref b in
    if b==a then () else begin
      occur_check a b ;
      begin match a.descr with
        | EVar (i,constraints) ->
            List.iter
              (function
                 | Getter g ->
                     let error = Unsatisfied_constraint (Getter g, b) in
                       begin match b.descr with
                         | Ground g' -> if g<>g' then raise error
                         | Arrow([],t) ->
                             begin match (deref t).descr with
                               | Ground g' -> if g<>g' then raise error
                               | EVar (j,c) ->
                                   (* This is almost wrong as it flips <: into
                                    * >:, but that's OK for a ground type. *)
                                   bind t (make (Ground g))
                               | _ -> raise error
                             end
                         | EVar (j,c) ->
                             if List.mem (Getter g) c then () else
                               b.descr <- EVar (j,(Getter g)::c)
                         | _ -> raise error
                       end
                 | Ord ->
                     (** In check, [b] is assumed to be dereferenced *)
                     let rec check b =
                       match b.descr with
                         | Ground g -> ()
                         | EVar (j,c) ->
                             if List.mem Ord c then () else
                               b.descr <- EVar (j,Ord::c)
                         | Product (b1,b2) ->
                             check (deref b1) ; check (deref b2)
                         | List b -> check (deref b)
                         | _ -> raise (Unsatisfied_constraint (Ord,b))
                     in
                       check b
                 | Dtools ->
                     begin match b.descr with
                       | Ground g ->
                           if not (List.mem g [Bool;Int;Float;String]) then
                             raise (Unsatisfied_constraint (Dtools,b))
                       | List b' ->
                           begin match (deref b').descr with
                             | Ground g ->
                                 if g <> String then
                                   raise (Unsatisfied_constraint (Dtools,b'))
                             | EVar (j,c) ->
                                 bind b' (make (Ground String))
                             | _ -> raise (Unsatisfied_constraint (Dtools,b'))
                           end
                       | EVar (j,c) ->
                           if not (List.mem Dtools c) then
                             b.descr <- EVar (j,Dtools::c)
                       | _ -> raise (Unsatisfied_constraint (Dtools,b))
                     end
                 | Num ->
                     begin match b.descr with
                       | Ground g ->
                           if g<>Int && g<>Float then
                             raise (Unsatisfied_constraint (Num,b))
                       | EVar (j,c) ->
                           if List.mem Num c then () else
                             b.descr <- EVar (j,Num::c)
                       | _ -> raise (Unsatisfied_constraint (Num,b))
                     end
                 | Arity_any ->
                     let rec check b = match b.descr with
                       | Zero | Variable -> ()
                       | Succ b -> check (deref b)
                       | EVar (j,c) ->
                           if List.mem Arity_any c then () else
                             b.descr <- EVar (j,Arity_any::c)
                       | _ -> raise (Unsatisfied_constraint (Arity_any,b))
                     in check b
                 | Arity_fixed ->
                     let rec check b = match b.descr with
                       | Zero -> ()
                       | Succ b -> check (deref b)
                       | EVar (j,c) ->
                           if List.mem Arity_fixed c then () else
                             b.descr <- EVar (j,Arity_fixed::c)
                       | _ -> raise (Unsatisfied_constraint (Arity_fixed,b))
                     in check b)
              constraints
        | _ -> assert false (* only EVars are bindable *)
      end ;
      (** This is a shaky hack...
        * When a value is passed to a FFI, its type is bound to a type without
        * any location.
        * If it doesn't break sharing, we set the parsing position of
        * that variable occurrence to the position of the infered type. *)
      if b.pos = None && match b.descr with EVar _ -> false | _ -> true
      then
        a.descr <- Link { a0 with descr = b.descr }
      else
        a.descr <- Link b
    end

(* {1 Subtype checking/inference} *)

type trace_item = Item of t*t | Flip
exception Error of (repr*repr)
type explanation = bool*t*t*repr*repr
exception Type_Error of explanation

let pp_type f t = print_repr f (repr t)
let pp_type_generalized generalized f t = print_repr f (repr ~generalized t)

let print ?generalized t : string =
  print_repr Format.str_formatter (repr ?generalized t) ;
  Format.fprintf Format.str_formatter "@?" ;
  Format.flush_str_formatter ()

let print_type_error (flipped,ta,tb,a,b) =
  let infered_pos a =
    let dpos = (deref a).pos in
      if a.pos = dpos then "" else
        match dpos with
          | None -> ""
          | Some p -> " (infered at " ^ print_pos ~prefix:"" p ^ ")"
  in
  let ta,tb,a,b = if flipped then tb,ta,b,a else ta,tb,a,b in
    Format.printf
      "@[<hv 2>%s:@ this value has type@;<1 2>%a%s@ "
      (match ta.pos with
         | None -> "At unknown position"
         | Some p -> print_pos p)
      print_repr a
      (infered_pos ta) ;
    Format.printf
      "but it should be a %stype of%s@;<1 2>%a%s@]@."
      (if flipped then "super" else "sub")
      (match tb.pos with
         | None -> ""
         | Some p ->
             Printf.sprintf " (the type of the value at %s)"
               (print_pos ~prefix:"" p))
      print_repr b
      (infered_pos tb)

let doc_of_type ~generalized t =
  let margin = Format.pp_get_margin Format.str_formatter () in
    Format.pp_set_margin Format.str_formatter 58 ;
    Format.fprintf
      Format.str_formatter
      "%a@?" (pp_type_generalized generalized) t ;
    Format.pp_set_margin Format.str_formatter margin ;
    Doc.trivial (Format.flush_str_formatter ())

(* I'd like to add subtyping on unions of scalar types, but for now the only
 * non-trivial thing is the arrow.
 * We allow
 *  (L1@L2)->T <: (L1)->T        if L2 is purely optional
 *  (L1@L2)->T <: (L1)->(L2)->T  otherwise (at least one mandatory param in L2)
 *
 * Memo: A <: B means that any value of type A can be passed where a value
 * of type B can. Indeed, if you can pass a function, you can also pass the same
 * one with extra optional parameters.
 *
 * This relation must be transitive. Note that it is not safe to allow the
 * promotion of optional parameters into mandatory ones, because the function
 * with the optional parameter, when fully applied, applies implicitely its
 * optional argument; whereas with a mandatory argument it is expected to wait
 * for it. *)

let constr_sub x y =
  match x,y with
    | _,_ when x=y -> true
    | "active_source", "source" -> true
    | _ -> false

(** Ensure that a<:b, perform unification if needed.
  * In case of error, generate an explaination. *)
let rec (<:) a b =
  if debug then Printf.eprintf "%s <: %s\n%!" (print a) (print b) ;
  match (deref a).descr, (deref b).descr with
    | Constr c1, Constr c2 when constr_sub c1.name c2.name ->
        let rec aux pre p1 p2 =
          match p1,p2 with
            | (v,h1)::t1,(_,h2)::t2 ->
                begin try
                  (* TODO use variance info *)
                  h1 <: h2
                with
                  | Error (a,b) ->
                      let post = List.map (fun (v,_) -> v,`Ellipsis) t1 in
                        raise (Error (`Constr (c1.name, pre@[v,a]@post),
                                      `Constr (c1.name, pre@[v,b]@post)))
                end ;
                aux ((v,`Ellipsis)::pre) t1 t2
            | [],[] -> ()
            | _ -> assert false (* same name => same arity *)
        in
          aux [] c1.params c2.params
    | List t1, List t2 ->
        begin try t1 <: t2 with
          | Error (a,b) -> raise (Error (`List a, `List b))
        end
    | Product (a,b), Product (aa,bb) ->
        begin try a <: aa with
          | Error (a,b) -> raise (Error (`Product (a,`Ellipsis),
                                         `Product (b,`Ellipsis)))
        end ;
        begin try b <: bb with
          | Error (a,b) -> raise (Error (`Product (`Ellipsis,a),
                                         `Product (`Ellipsis,b)))
        end
    | Record r1, Record r2 ->
      (* TODO: we could drop some generalized variables that are not used anymore. *)
      let rec1, row1 = merge_record r1 in
      let rec2, row2 = merge_record r2 in
      List.iter
        (fun (x,(g2,t2)) ->
          try
            let t1 = snd (List.assoc x rec1) in
            try t1 <: t2 with
              | Error (a,b) ->
                let rec1, row1 = merge_record r1 in
                (* TODO: correctly display the generalized variables *)
                let rec1 = List.map (fun (x',(g,_)) -> x', if x' = x then ([],a) else ([],`Ellipsis)) rec1 in
                let rec2 = List.map (fun (x',(g,_)) -> x', if x' = x then ([],b) else ([],`Ellipsis)) rec2 in
                raise (Error (`Record (rec1, Utils.may repr row1), `Record (rec2, Utils.may repr row2)))
          with
            | Not_found ->
              match row1 with
                | None ->
                  (* No row type, sorry. *)
                  let rec1 = List.map (fun (x',(g1,t1)) -> x', if x' = x then repr ~generalized:g1 t1 else `Ellipsis) rec1 in
                  let rec2 =
                    (* Handles both records and non-records *)
                    let fo = ref false in
                    let filter_out _ = !fo || (fo := true; false) in
                    repr ~filter_out (deref b)
                  in
                  (* TODO: correctly display the generalized variables *)
                  let rec1 = List.map (fun (x,r) -> x,([],r)) rec1 in
                  raise (Error (`Record (rec1, Utils.may repr row1), rec2))
                | Some row1 ->
                  (* We have a row type, add a field to it. *)
                  if is_evar row1 then
                    (
                      let fresh = record ~level:row1.level ~row:true [] in
                      row1.descr <- Link fresh
                    );
                  let t, (r, row) =
                    match row1.descr with
                      | Link ({ descr = Record r } as t) -> t, r
                      | _ -> assert false
                  in
                  let r = (x,(g2,t2))::r in
                  let t = { t with descr = Record (r, row) } in
                  row1.descr <- Link t
        ) rec2;
        (* Then we unify the row variables. *)
        let rec1, row1 = merge_record r1 in
        (
          match row1, row2 with
            | None, None -> ()
            | None, Some row2 ->
              let rec1 = List.filter (fun (x,_) -> not (List.mem_assoc x rec2)) rec1 in
              row2.descr <- Link (make ~level:row2.level (Record (rec1, None)))
            | Some row1, None -> ()
            | Some row1, Some row2 ->
              (* Occurs-check *)
              if row1 <> row2 then
                (* Unify *)
                row1.descr <- Link (make ~level:row1.level (Record ([], Some row2)))
        )
    | Zero, Zero -> ()
    | Zero, Variable -> ()
    | Succ t1, Succ t2 ->
        begin try t1 <: t2 with
          | Error (a,b) -> raise (Error (`Succ a, `Succ b))
        end
    | Succ t1, Variable ->
        begin try t1 <: b with
          | Error (a,b) -> raise (Error (`Succ a, b))
        end
    | Variable, Variable -> ()
    | Arrow (l12,t), Arrow (l,t') ->
        (* Here, it must be that l12 = l1@l2
         * where l1 is essentially l modulo order
         * and either l2 is erasable and t<:t'
         *        or (l2)->t <: t'. *)
        let ellipsis = false,"",`Range_Ellipsis in
        let elide (o,l,t) = o,l,`Ellipsis in
        let l1,l2 =
          List.fold_left
            (* Start with [l2:=l12], [l1:=[]] and
             * move each param [o,lbl] required by [l] from [l2] to [l1]. *)
            (fun (l1,l2) (o,lbl,t) ->
               (* Search for a param with optionality o and label lbl.
                * Returns the first matching parameter
                * and the list without it. *)
               let rec get_param acc = function
                 | [] ->
                     raise (Error (`Arrow (List.rev_append l1
                                             (List.map elide l2),
                                           `Ellipsis),
                                   `Arrow (List.rev (ellipsis::
                                                     (o,lbl,`Ellipsis)::
                                                     l1),
                                           `Ellipsis)))
                 | (o',lbl',t')::tl ->
                    if o=o' && lbl=lbl' then
                      (o,lbl,t'), List.rev_append acc tl
                    else
                      get_param ((o',lbl',t')::acc) tl
               in
               let ((o,lbl,t'),l2') = get_param [] l2 in
                 (* Check on-the-fly that the types match. *)
                 begin try t<:t' with
                   | Error (t,t') ->
                       let make t =
                         `Arrow (List.rev (ellipsis::(o,lbl,t)::l1),
                                 `Ellipsis)
                       in
                         raise (Error (make t', make t))
                 end ;
                 ((o,lbl,`Ellipsis)::l1),l2')
            ([],l12)
            l
        in
        let l1 = List.rev l1 in
          if List.for_all (fun (o,_,_) -> o) l2 then
            begin try t <: t' with
              | Error (t,t') ->
                  raise (Error (`Arrow([ellipsis],t),`Arrow([ellipsis],t')))
            end
          else
            begin try { a with descr = Arrow (l2,t) } <: t' with
              | Error (`Arrow(p,t),t') ->
                  raise (Error (`Arrow(l1@p,t),`Arrow(l1,t')))
              | Error _ -> assert false
            end
    | Ground x,Ground y ->
        if x <> y then raise (Error (repr a,repr b))
    (* The EVar cases doing bind are abusive because of subtyping.
     * In general we would need subtyping constraints, but that's
     * a very different story, and it would be very hairy for arrows.
     * For now we do with a couple special cases regarding arities... *)
    | EVar (_,c), Variable when List.mem Arity_fixed c -> ()
    | EVar (_,c), Variable when List.mem Arity_any c -> ()
    | EVar (_,c), Succ b' ->
        (* This could be optimized to process a bunch of succ all at once.
         * But it doesn't matter. The point is that binding might fail,
         * and is too abusive anyway. *)
        let a' = fresh_evar ~level:a.level ~constraints:[] ~pos:None in
        begin try bind a (make ~pos:a.pos (Succ a')) with
          | Unsatisfied_constraint _ ->
              raise (Error (repr a, repr b))
        end ;
        begin try a' <: b' with
          | Error (a',b') -> raise (Error (`Succ a', `Succ b'))
        end
    | Succ a', EVar (_,c) ->
        let b' = fresh_evar ~level:b.level ~constraints:[] ~pos:None in
        begin try bind b (make ~pos:b.pos (Succ b')) with
          | Unsatisfied_constraint _ ->
              raise (Error (repr a, repr b))
        end ;
        begin try a' <: b' with
          | Error (a',b') -> raise (Error (`Succ a', `Succ b'))
        end
    | EVar _, _ ->
        begin try bind a b with
          | Occur_check _ | Unsatisfied_constraint _ ->
              (* Can't do more concise than a full representation,
               * as the problem isn't local. *)
              raise (Error (repr a,repr b))
        end
    | _, EVar _ ->
        begin try bind b a with
          | Occur_check _ | Unsatisfied_constraint _ ->
              raise (Error (repr a,repr b))
        end
    | Link _,_ | _,Link _ -> assert false (* thanks to deref *)
    | _,_ ->
        (* The superficial representation is enough for explaining
         * the mismatch. *)
        let filter () =
          let already = ref false in
            function
              | {descr = Link _} -> false
              | _ -> let x = !already in already := true ; x
        in
        let a = repr ~filter_out:(filter ()) a in
        let b = repr ~filter_out:(filter ()) b in
          raise (Error (a,b))

let (>:) a b =
  try b <: a with Error (y,x) -> raise (Type_Error (true,b,a,y,x))

let (<:) a b =
  try a <: b with Error (x,y) -> raise (Type_Error (false,a,b,x,y))

(** {1 Type generalization and instantiation}
  *
  * We don't have type schemes per se, but we compute generalizable variables
  * and keep track of them in the AST.
  * This is simple and useful because in any case we need to distinguish
  * two 'a variables bound at different places. Indeed, we might instantiate
  * one in a term where the second is bound, and we don't want to
  * merge the two when going under the binder.
  *
  * When generalizing we need to know what can be generalized in the outermost
  * type but also in the inner types of the term forming a let-definition.
  * Indeed those variables will have to be instantiated by fresh ones for
  * every instance.
  *
  * If the value restriction applies, then we have some (fun (...) -> ...)
  * and any type variable of higher level can be generalized, whether it's
  * in the outermost type or not. *)

let filter_vars f t =
  let rec aux ?(generalized=[]) l t =
    let aux ?(generalized=generalized) l t = aux ~generalized l t in
    let t = deref t in
    match t.descr with
    | Ground _ | Zero | Variable -> l
    | Succ t | List t -> aux l t
    | Product (a,b) -> aux (aux l a) b
    | Constr c ->
        List.fold_left (fun l (_,t) -> aux l t) l c.params
    | Arrow (p,t) ->
        aux (List.fold_left (fun l (_,_,t) -> aux l t) l p) t
    | EVar ic ->
        if not (List.mem ic generalized) && not (List.mem ic l) && f t then ic::l else l
    | Link _ -> assert false
    | Record r ->
      let r,row = merge_record r in
      let l =
        match row with
          | Some row ->
            (* TODO: this does not belong to the general filter_vars functions,
               but it is only used by generalizable for now... *)
            let l =
              let row =
                match (deref row).descr with
                  | EVar ic -> ic
                  | _ -> assert false
              in
              if not (List.mem row generalized) && not (List.mem row l) then row::l else l
            in
            aux l row
          | None -> l
      in
      List.fold_left (fun l (x,(g,t)) -> aux ~generalized:(g@generalized) l t) l r
  in
  aux [] t

(** Return a list of generalizable variables in a type.
    * This is performed after type inference on the left-hand side
    * of a let-in, with [level] being the level of that let-in.
    * Uses the simple method of ML, to be associated with a value restriction. *)
let generalizable ?level t =
  let level =
    match level with
      | Some l -> l
      | None -> t.level
  in
  filter_vars (fun t -> t.level >= level) t

let generalize ?level t =
  let g = generalizable ?level t in
  g,t

(** Copy a term, substituting some EVars as indicated by a list
  * of associations. Other EVars are not copied, so sharing is
  * preserved. *)
let copy_with subst t =
  let rec aux t =
    let cp x = { t with descr = x } in
      match t.descr with
        | EVar (i,c) ->
            begin try
              snd (List.find (fun ((j,_),_) -> i=j) subst)
            with
              | Not_found -> t
            end
        | Constr c ->
            let params = List.map (fun (v,t) -> v, aux t) c.params in
              cp (Constr { c with params = params })
        | Ground _ -> cp t.descr
        | List t -> cp (List (aux t))
        | Product (a,b) -> cp (Product (aux a, aux b))
        | Zero | Variable -> cp t.descr
        | Succ t -> cp (Succ (aux t))
        | Arrow (p,t) ->
            cp (Arrow (List.map (fun (o,l,t) -> (o,l,aux t)) p, aux t))
        | Link t ->
            (* Keep links to preserve rich position information,
             * and to make it possible to check if the application left
             * the type unchanged. *)
            cp (Link (aux t))
        | Record r ->
          let r, row = merge_record r in
          (* TODO: hide variables from g in the substitution! *)
          let r = List.map (fun (x,(g,t)) -> x, (g, aux t)) r in
          let row = Utils.may aux row in
          cp (Record (r, row))
  in
    aux t

module M = Map.Make(struct type t = int let compare = compare end)

(** Instantiate a type scheme, given as a type together with a list
  * of generalized variables.
  * Fresh variables are created with the given (current) level,
  * and attached to the appropriate constraints.
  * This erases position information, since they usually become
  * irrelevant. *)
let instantiate ~level ~generalized =
  let subst =
    List.map
      (fun (i,c) -> (i,c), fresh_evar ~level ~constraints:c ~pos:None)
      generalized
  in
    fun t -> copy_with subst t

(** Simplified version of existential variable generation,
  * without constraints. This is used when parsing to annotate
  * the AST. *)
let fresh = fresh_evar
let fresh_evar = fresh_evar ~constraints:[]
