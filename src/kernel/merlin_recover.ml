open Std
open Raw_parser

let section = Logger.section "recover"

let rollbacks endp parser =
  let rec aux (termination,_,parser) =
    (* FIXME: find proper way to handle limit conditions *)
    (* When reaching bottom of the stack, last frame will raise an Accept
       exception, we can't recover from it, and we shouldn't recover TO it. *)
    try
      match Merlin_parser.recover ~endp termination parser with
      | Some _ as r -> r
      | None ->
        Option.map ~f:(fun a -> Merlin_parser.termination, 0, a)
          (Merlin_parser.pop parser)
    with _ -> None
  in
  let parser = Merlin_parser.termination, 0, parser in
  let stacks = parser :: List.unfold aux parser in
  let stacks = List.rev_map stacks ~f:(fun (_,a,b) -> a,b) in
  (* Hack to drop last parser *)
  let stacks =
    List.sort (fun (_,p1) (_,p2) ->
        let p1 = Merlin_parser.location p1 in
        let p1 = p1.Location.loc_start in
        let _, p1 = Lexing.split_pos p1 in
        let p2 = Merlin_parser.location p2 in
        let p2 = p2.Location.loc_start in
        let _, p2 = Lexing.split_pos p2 in
        - compare p1 p2)
      stacks
  in
  Zipper.of_list stacks

type t = {
  errors: exn list;
  parser: Merlin_parser.t;
  recovering: ((int * Merlin_parser.t) zipper) option;
}

let parser t = t.parser
let exns t = t.errors

let fresh parser = {errors = []; parser; recovering = None}

let token_to_string tok =
  let open Merlin_parser.Values in
  string_of_class (class_of_symbol (symbol_of_token tok))

let rec feed_normal (s,tok,e as input) parser =
  let dump_token token = `Assoc [
      "token", `String (token_to_string token)
    ]
  in
  match Merlin_parser.feed input parser with
  | `Accept _ ->
    Logger.debugjf section ~title:"feed_normal accepted" dump_token tok;
    assert (tok = EOF);
    feed_normal (s,SEMISEMI,e) parser
  | `Reject ->
    Logger.debugjf section ~title:"feed_normal rejected" dump_token tok;
    None
  | `Step parser ->
    Logger.debugjf section ~title:"feed_normal step" dump_token tok;
    Some parser

let closing_token = function
  | END -> true
  | RPAREN -> true
  | _ -> false

let prepare_candidates candidates =
  let open Location in
  let candidates = List.rev candidates in
  (*let candidates = List.group_by
      (fun (a : _ loc) (b : _ loc) ->
        Lexing.compare_pos a.loc.loc_start b.loc.loc_start = 0)
      candidates
  in*)
  let cmp (pa,_) (pb,_) =
    - compare pa pb
  in
  (*List.concat_map (List.stable_sort ~cmp) candidates*)
  List.stable_sort ~cmp candidates


let feed_recover original (s,tok,e as input) zipper =
  let get_col x = snd (Lexing.split_pos x) in
  let ref_col = get_col s in
  (* Find appropriate recovering position *)
  let less_indented (_,p) =
    let loc = Merlin_parser.location p in
    get_col loc.Location.loc_start <= ref_col
  and more_indented (_,p) =
    let loc = Merlin_parser.location p in
    get_col loc.Location.loc_start >= ref_col
  in
  (* Backward: increase column *)
  (* Forward: decrease column *)
  (*let zipper = Zipper.seek_forward more_indented zipper in
  let zipper = Zipper.seek_backward less_indented zipper in
    let candidates = prepare_candidates (Zipper.select_forward more_indented zipper) in*)
  let Zipper (_,_,candidates) = zipper in
  let candidates = prepare_candidates candidates in
  Logger.infojf section ~title:"feed_recover candidates"
    (fun (pos,candidates) ->
      `Assoc [
        "position", Lexing.json_of_position pos;
        "candidates",
        let dump_snapshot n (priority,parser) = `Assoc [
            "number", `Int n;
            "priority", `Int priority;
            "parser", Merlin_parser.dump parser;
          ]
        in
        `List (List.mapi ~f:dump_snapshot candidates)
      ])
    (s,candidates);
  let rec aux_feed n = function
    | [] -> Either.L zipper
    | (_,candidate) :: candidates ->
      aux_dispatch candidates n candidate
        (Merlin_parser.feed input candidate)

  and aux_dispatch candidates n candidate = function
    | `Step parser ->
      Logger.infojf section ~title:"feed_recover selected"
        (fun (n,parser) ->
          `Assoc ["number", `Int n;
                  "parser", Merlin_parser.dump parser])
        (n,parser);
      Either.R parser
    | `Accept _ ->
      Logger.debugjf section ~title:"feed_recover accepted"
        (fun n -> `Assoc ["number", `Int n]) n;
      assert (tok = EOF);
      aux_dispatch candidates n candidate
        (Merlin_parser.feed (s,SEMISEMI,e) candidate)
    | `Reject ->
      Logger.debugjf section ~title:"feed_recover rejected"
        (fun n -> `Assoc ["number", `Int n]) n;
      aux_feed (n + 1) candidates

  in
  aux_feed 0 candidates

let fold warnings token t =
  match token with
  | Merlin_lexer.Error _ -> t
  | Merlin_lexer.Valid (s,tok,e) ->
    warnings := [];
    let pop w = let r = !warnings in w := []; r in
    let recover_from t recovery =
      match feed_recover t.parser (s,tok,e) recovery with
      | Either.L recovery ->
        {t with recovering = Some recovery}
      | Either.R parser ->
        {t with parser; recovering = None}
    in
    match t.recovering with
    | Some recovery -> recover_from t recovery
    | None ->
      begin match feed_normal (s,tok,e) t.parser with
        | None ->
          let recovery = rollbacks e t.parser in
          let step = Merlin_parser.to_step t.parser in
          let error = Error_classifier.from step (s,tok,e) in
          recover_from
            {t with errors = error :: (pop warnings) @ t.errors}
            recovery
        | Some parser ->
          {t with errors = (pop warnings) @ t.errors; parser }
      end

let fold token t =
  let warnings = ref [] in
  Either.get (Parsing_aux.catch_warnings warnings
                (fun () -> fold warnings token t))

let dump_recovering = function
  | None -> `Null
  | Some (Zipper (head, _, tail)) ->
    let dump_snapshot (priority,parser) =
      `Assoc [
        "priority", `Int priority;
        "parser", Merlin_parser.dump parser
      ]
    in
    `Assoc [
      "head", `List (List.map ~f:dump_snapshot head);
      "tail", `List (List.map ~f:dump_snapshot tail);
    ]

let dump t = `Assoc [
    "parser", Merlin_parser.dump t.parser;
    "recovery", dump_recovering t.recovering;
  ]

let dump_recoverable t =
  let t = match t.recovering with
    | Some _ -> t
    | None -> {t with recovering = Some (rollbacks Lexing.dummy_pos t.parser)}
  in
  dump t
