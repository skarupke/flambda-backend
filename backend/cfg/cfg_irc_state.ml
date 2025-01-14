[@@@ocaml.warning "+a-4-30-40-41-42"]

open! Cfg_regalloc_utils
open! Cfg_irc_utils

module RegWorkList =
  WorkList.Make
    (struct
      type t = Reg.t

      let compare left right = Int.compare left.Reg.stamp right.Reg.stamp
    end)
    (Reg.Set)

module InstructionWorkList = WorkList.Make (Instruction) (Instruction.Set)

type t =
  { mutable initial : Reg.t list;
    mutable simplify_work_list : RegWorkList.t;
    mutable freeze_work_list : RegWorkList.t;
    mutable spill_work_list : RegWorkList.t;
    mutable spilled_nodes : RegWorkList.t;
    mutable coalesced_nodes : RegWorkList.t;
    mutable colored_nodes : Reg.t list;
    mutable select_stack : Reg.t list;
    mutable coalesced_moves : InstructionWorkList.t;
    mutable constrained_moves : InstructionWorkList.t;
    mutable frozen_moves : InstructionWorkList.t;
    mutable work_list_moves : InstructionWorkList.t;
    mutable active_moves : InstructionWorkList.t;
    adj_set : RegisterStamp.PairSet.t;
    move_list : Instruction.Set.t Reg.Tbl.t;
    stack_slots : int Reg.Tbl.t;
    num_stack_slots : int array;
    mutable next_instruction_id : Instruction.id;
    mutable introduced_temporaries : Reg.Set.t
  }

let[@inline] make ~initial ~next_instruction_id () =
  List.iter (Reg.all_registers ()) ~f:(fun reg ->
      reg.Reg.irc_work_list <- Unknown_list;
      reg.Reg.irc_color <- None;
      reg.Reg.irc_alias <- None;
      reg.Reg.interf <- [];
      reg.Reg.degree <- 0);
  List.iter initial ~f:(fun reg -> reg.Reg.irc_work_list <- Initial);
  Array.iter all_precolored_regs ~f:(fun reg ->
      reg.Reg.irc_work_list <- Reg.Precolored;
      reg.Reg.irc_color
        <- (match reg.Reg.loc with
           | Reg color -> Some color
           | Unknown | Stack _ ->
             fatal "precolored register %a is not an hardware register"
               Printmach.reg reg);
      reg.Reg.irc_alias <- None;
      reg.Reg.interf <- [];
      reg.Reg.degree <- Degree.infinite);
  let num_registers = List.length initial in
  let expected_max_size = num_registers in
  let simplify_work_list = RegWorkList.make ~expected_max_size in
  let freeze_work_list = RegWorkList.make ~expected_max_size in
  let spill_work_list = RegWorkList.make ~expected_max_size in
  let spilled_nodes = RegWorkList.make ~expected_max_size in
  let coalesced_nodes = RegWorkList.make ~expected_max_size in
  let colored_nodes = [] in
  let select_stack = [] in
  let expected_max_size = pred next_instruction_id in
  let coalesced_moves = InstructionWorkList.make ~expected_max_size in
  let constrained_moves = InstructionWorkList.make ~expected_max_size in
  let frozen_moves = InstructionWorkList.make ~expected_max_size in
  let work_list_moves = InstructionWorkList.make ~expected_max_size in
  let active_moves = InstructionWorkList.make ~expected_max_size in
  let adj_set = RegisterStamp.PairSet.make ~num_registers in
  let move_list = Reg.Tbl.create 128 in
  let stack_slots = Reg.Tbl.create 128 in
  let num_stack_slots = Array.make Proc.num_register_classes 0 in
  let introduced_temporaries = Reg.Set.empty in
  { initial;
    simplify_work_list;
    freeze_work_list;
    spill_work_list;
    spilled_nodes;
    coalesced_nodes;
    colored_nodes;
    select_stack;
    coalesced_moves;
    constrained_moves;
    frozen_moves;
    work_list_moves;
    active_moves;
    adj_set;
    move_list;
    stack_slots;
    num_stack_slots;
    next_instruction_id;
    introduced_temporaries
  }

let[@inline] add_initial_one state reg =
  reg.Reg.irc_work_list <- Initial;
  reg.Reg.irc_color <- None;
  reg.Reg.irc_alias <- None;
  reg.Reg.interf <- [];
  reg.Reg.degree <- 0;
  state.initial <- reg :: state.initial

let[@inline] add_initial_list state regs =
  List.iter regs ~f:(fun reg ->
      reg.Reg.irc_work_list <- Initial;
      reg.Reg.irc_color <- None;
      reg.Reg.irc_alias <- None;
      reg.Reg.interf <- [];
      reg.Reg.degree <- 0);
  state.initial <- regs @ state.initial

let[@inline] reset state ~new_temporaries =
  let unknown_reg_work_list (rwl : RegWorkList.t) : unit =
    RegWorkList.iter rwl ~f:(fun reg -> reg.irc_work_list <- Unknown_list)
  in
  let unknown_instruction_work_list (iwl : InstructionWorkList.t) : unit =
    InstructionWorkList.iter iwl ~f:(fun instr ->
        instr.irc_work_list <- Unknown_list)
  in
  List.iter (Reg.all_registers ()) ~f:(fun reg ->
      reg.Reg.irc_color <- None;
      reg.Reg.irc_alias <- None;
      reg.Reg.interf <- [];
      reg.Reg.degree <- 0);
  Array.iter all_precolored_regs ~f:(fun reg ->
      assert (reg.Reg.irc_work_list = Reg.Precolored);
      (match reg.Reg.loc, reg.Reg.irc_color with
      | Reg color, Some color' -> assert (color = color')
      | Reg _, None -> assert false
      | (Unknown | Stack _), _ -> assert false);
      reg.Reg.irc_alias <- None;
      reg.Reg.interf <- [];
      assert (reg.Reg.degree = Degree.infinite));
  state.initial
    <- new_temporaries @ state.colored_nodes
       @ RegWorkList.to_list state.coalesced_nodes;
  List.iter state.initial ~f:(fun reg -> reg.Reg.irc_work_list <- Initial);
  unknown_reg_work_list state.simplify_work_list;
  state.simplify_work_list <- RegWorkList.empty state.simplify_work_list;
  unknown_reg_work_list state.freeze_work_list;
  state.freeze_work_list <- RegWorkList.empty state.freeze_work_list;
  unknown_reg_work_list state.spill_work_list;
  state.spill_work_list <- RegWorkList.empty state.spill_work_list;
  unknown_reg_work_list state.spilled_nodes;
  state.spilled_nodes <- RegWorkList.empty state.spilled_nodes;
  state.coalesced_nodes <- RegWorkList.empty state.coalesced_nodes;
  state.colored_nodes <- [];
  assert (state.select_stack = []);
  unknown_instruction_work_list state.coalesced_moves;
  state.coalesced_moves <- InstructionWorkList.empty state.coalesced_moves;
  unknown_instruction_work_list state.constrained_moves;
  state.constrained_moves <- InstructionWorkList.empty state.constrained_moves;
  unknown_instruction_work_list state.frozen_moves;
  state.frozen_moves <- InstructionWorkList.empty state.frozen_moves;
  unknown_instruction_work_list state.work_list_moves;
  state.work_list_moves <- InstructionWorkList.empty state.work_list_moves;
  unknown_instruction_work_list state.active_moves;
  state.active_moves <- InstructionWorkList.empty state.active_moves;
  RegisterStamp.PairSet.clear state.adj_set;
  Reg.Tbl.clear state.move_list;
  state.introduced_temporaries
    <- List.fold_left new_temporaries ~init:state.introduced_temporaries
         ~f:(fun acc reg -> Reg.Set.add reg acc)

let[@inline] is_precolored _state reg = reg.Reg.irc_work_list = Reg.Precolored

let[@inline] is_precolored_or_colored _state reg =
  reg.Reg.irc_work_list = Reg.Precolored || reg.Reg.irc_work_list = Reg.Colored

let[@inline] get_and_clear_initial state =
  List.iter state.initial ~f:(fun reg -> reg.Reg.irc_work_list <- Unknown_list);
  let res = state.initial in
  state.initial <- [];
  res

let[@inline] is_empty_simplify_work_list state =
  RegWorkList.is_empty state.simplify_work_list

let[@inline] add_simplify_work_list state reg =
  reg.Reg.irc_work_list <- Reg.Simplify;
  state.simplify_work_list <- RegWorkList.add state.simplify_work_list reg

let[@inline] choose_and_remove_simplify_work_list state =
  match RegWorkList.choose_and_remove state.simplify_work_list with
  | None -> fatal "simplify_work_list is empty"
  | Some (res, rwl) ->
    res.Reg.irc_work_list <- Reg.Unknown_list;
    state.simplify_work_list <- rwl;
    res

let[@inline] is_empty_freeze_work_list state =
  RegWorkList.is_empty state.freeze_work_list

let[@inline] mem_freeze_work_list _state reg =
  reg.Reg.irc_work_list = Reg.Freeze

let[@inline] add_freeze_work_list state reg =
  reg.Reg.irc_work_list <- Reg.Freeze;
  state.freeze_work_list <- RegWorkList.add state.freeze_work_list reg

let[@inline] remove_freeze_work_list state reg =
  reg.Reg.irc_work_list <- Reg.Unknown_list;
  state.freeze_work_list <- RegWorkList.remove state.freeze_work_list reg

let[@inline] choose_and_remove_freeze_work_list state =
  match RegWorkList.choose_and_remove state.freeze_work_list with
  | None -> fatal "freeze_work_list is empty"
  | Some (res, rwl) ->
    res.Reg.irc_work_list <- Reg.Unknown_list;
    state.freeze_work_list <- rwl;
    res

let[@inline] is_empty_spill_work_list state =
  RegWorkList.is_empty state.spill_work_list

let[@inline] mem_spill_work_list _state reg = reg.Reg.irc_work_list = Reg.Spill

let[@inline] add_spill_work_list state reg =
  reg.Reg.irc_work_list <- Reg.Spill;
  state.spill_work_list <- RegWorkList.add state.spill_work_list reg

let[@inline] remove_spill_work_list state reg =
  reg.Reg.irc_work_list <- Reg.Unknown_list;
  state.spill_work_list <- RegWorkList.remove state.spill_work_list reg

let[@inline] fold_spill_work_list state ~f ~init =
  RegWorkList.fold state.spill_work_list ~f ~init

let[@inline] spill_work_list state = RegWorkList.to_set state.spill_work_list

let[@inline] is_empty_spilled_nodes state =
  RegWorkList.is_empty state.spilled_nodes

let[@inline] add_spilled_nodes state reg =
  reg.Reg.irc_work_list <- Reg.Spilled;
  state.spilled_nodes <- RegWorkList.add state.spilled_nodes reg

let[@inline] spilled_nodes state = RegWorkList.to_list state.spilled_nodes

let[@inline] clear_spilled_nodes state =
  RegWorkList.iter state.spilled_nodes ~f:(fun reg ->
      reg.Reg.irc_work_list <- Reg.Unknown_list);
  state.spilled_nodes <- RegWorkList.empty state.spilled_nodes

let[@inline] add_coalesced_nodes state reg =
  reg.Reg.irc_work_list <- Reg.Coalesced;
  state.coalesced_nodes <- RegWorkList.add state.coalesced_nodes reg

let[@inline] iter_coalesced_nodes state ~f =
  RegWorkList.iter state.coalesced_nodes ~f

let[@inline] add_colored_nodes state reg =
  reg.Reg.irc_work_list <- Reg.Colored;
  state.colored_nodes <- reg :: state.colored_nodes

let[@inline] is_empty_select_stack state = state.select_stack = []

let[@inline] push_select_stack state reg =
  reg.Reg.irc_work_list <- Reg.Select_stack;
  state.select_stack <- reg :: state.select_stack

let[@inline] pop_select_stack state =
  match state.select_stack with
  | [] -> fatal "select_stack is empty"
  | hd :: tl ->
    state.select_stack <- tl;
    hd.Reg.irc_work_list <- Reg.Unknown_list;
    hd

let[@inline] iter_and_clear_select_stack state ~f =
  List.iter state.select_stack ~f;
  state.select_stack <- []

let[@inline] add_coalesced_moves state instr =
  instr.Cfg.irc_work_list <- Coalesced;
  state.coalesced_moves <- InstructionWorkList.add state.coalesced_moves instr

let[@inline] add_constrained_moves state instr =
  instr.Cfg.irc_work_list <- Constrained;
  state.constrained_moves
    <- InstructionWorkList.add state.constrained_moves instr

let[@inline] add_frozen_moves state instr =
  instr.Cfg.irc_work_list <- Frozen;
  state.frozen_moves <- InstructionWorkList.add state.frozen_moves instr

let[@inline] is_empty_work_list_moves state =
  InstructionWorkList.is_empty state.work_list_moves

let[@inline] add_work_list_moves state instr =
  instr.Cfg.irc_work_list <- Work_list;
  state.work_list_moves <- InstructionWorkList.add state.work_list_moves instr

let[@inline] choose_and_remove_work_list_moves state =
  match InstructionWorkList.choose_and_remove state.work_list_moves with
  | None -> fatal "work_list_moves is empty"
  | Some (res, iwl) ->
    res.Cfg.irc_work_list <- Unknown_list;
    state.work_list_moves <- iwl;
    res

let[@inline] mem_active_moves _state instr =
  instr.Cfg.irc_work_list = Cfg.Active

let[@inline] add_active_moves state instr =
  instr.Cfg.irc_work_list <- Active;
  state.active_moves <- InstructionWorkList.add state.active_moves instr

let[@inline] remove_active_moves state instr =
  instr.Cfg.irc_work_list <- Unknown_list;
  state.active_moves <- InstructionWorkList.remove state.active_moves instr

let[@inline] mem_adj_set state reg1 reg2 =
  RegisterStamp.PairSet.mem state.adj_set
    (RegisterStamp.pair reg1.Reg.stamp reg2.Reg.stamp)

let[@inline] adj_list _state reg = reg.Reg.interf

let[@inline] add_edge state u v =
  let is_interesting_reg reg =
    match reg.Reg.loc with
    | Reg _ -> true
    | Unknown -> true
    | Stack (Local _ | Incoming _ | Outgoing _ | Domainstate _) -> false
  in
  let pair = RegisterStamp.pair u.Reg.stamp v.Reg.stamp in
  if (not (Reg.same u v))
     && is_interesting_reg u && is_interesting_reg v && same_reg_class u v
     && not (RegisterStamp.PairSet.mem state.adj_set pair)
  then (
    RegisterStamp.PairSet.add state.adj_set pair;
    let add_adj_list x y = x.Reg.interf <- y :: x.Reg.interf in
    let incr_degree x =
      let deg = x.Reg.degree in
      if irc_debug && deg = Degree.infinite
      then fatal "trying to increment the degree of a precolored node";
      x.Reg.degree <- succ deg
    in
    if not (is_precolored state u)
    then (
      add_adj_list u v;
      incr_degree u);
    if not (is_precolored state v)
    then (
      add_adj_list v u;
      incr_degree v))

let[@inline] iter_adjacent state reg ~f =
  List.iter (adj_list state reg) ~f:(fun reg ->
      match reg.Reg.irc_work_list with
      | Select_stack | Coalesced -> ()
      | _ -> f reg)

let[@inline] for_all_adjacent state reg ~f =
  List.for_all (adj_list state reg) ~f:(fun reg ->
      match reg.Reg.irc_work_list with
      | Select_stack | Coalesced -> true
      | _ -> f reg)

let[@inline] adj_set state = state.adj_set

let[@inline] is_empty_node_moves state reg =
  match Reg.Tbl.find_opt state.move_list reg with
  | None -> true
  | Some move_list ->
    not
      (Instruction.Set.exists
         (fun instr ->
           match instr.irc_work_list with
           | Active | Work_list -> true
           | _ -> false)
         move_list)

let[@inline] iter_node_moves state reg ~f =
  match Reg.Tbl.find_opt state.move_list reg with
  | None -> ()
  | Some move_list ->
    Instruction.Set.iter
      (fun instr ->
        match instr.irc_work_list with Active | Work_list -> f instr | _ -> ())
      move_list

let[@inline] is_move_related state reg =
  match Reg.Tbl.find_opt state.move_list reg with
  | None -> false
  | Some move_list ->
    Instruction.Set.exists
      (fun instr ->
        match instr.irc_work_list with Active | Work_list -> true | _ -> false)
      move_list

let[@inline] enable_moves_one state reg =
  let n = reg in
  iter_node_moves state n ~f:(fun m ->
      match m.irc_work_list with
      | Active ->
        m.irc_work_list <- Work_list;
        state.active_moves <- InstructionWorkList.remove state.active_moves m;
        state.work_list_moves <- InstructionWorkList.add state.work_list_moves m
      | _ -> ())

let[@inline] decr_degree state reg =
  let d = reg.Reg.degree in
  if d = Degree.infinite
  then ()
  else (
    reg.Reg.degree <- pred d;
    if Int.equal d (k reg)
    then (
      enable_moves_one state reg;
      iter_adjacent state reg ~f:(fun r -> enable_moves_one state r);
      reg.Reg.irc_work_list <- Reg.Unknown_list;
      state.spill_work_list <- RegWorkList.remove state.spill_work_list reg;
      if is_move_related state reg
      then (
        reg.Reg.irc_work_list <- Reg.Freeze;
        state.freeze_work_list <- RegWorkList.add state.freeze_work_list reg)
      else (
        reg.Reg.irc_work_list <- Reg.Simplify;
        state.simplify_work_list <- RegWorkList.add state.simplify_work_list reg)))

let[@inline] find_move_list state reg =
  match Reg.Tbl.find_opt state.move_list reg with
  | None -> Instruction.Set.empty
  | Some res -> res

let[@inline] add_move_list state reg instr =
  match Reg.Tbl.find_opt state.move_list reg with
  | None ->
    Reg.Tbl.replace state.move_list reg (Instruction.Set.singleton instr)
  | Some existing ->
    Reg.Tbl.replace state.move_list reg (Instruction.Set.add instr existing)

let[@inline] union_move_list state reg set =
  match Reg.Tbl.find_opt state.move_list reg with
  | None -> Reg.Tbl.replace state.move_list reg set
  | Some existing ->
    Reg.Tbl.replace state.move_list reg (Instruction.Set.union existing set)

let[@inline] rec find_alias state reg =
  if reg.Reg.irc_work_list = Reg.Coalesced
  then
    match reg.Reg.irc_alias with
    | None -> fatal "register %a has no alias" Printmach.reg reg
    | Some reg' -> find_alias state reg'
  else reg

let[@inline] add_alias _state v u =
  if not (same_reg_class v u)
  then
    fatal
      "trying to create an alias between %a and %a but they are in different \
       classes"
      Printmach.reg v Printmach.reg u;
  v.Reg.irc_alias <- Some u

let[@inline] get_and_incr_num_stack_slots state reg_class =
  let res = state.num_stack_slots.(reg_class) in
  state.num_stack_slots.(reg_class) <- succ res;
  res

let[@inline] get_num_stack_slot state reg =
  match Reg.Tbl.find_opt state.stack_slots reg with
  | Some slot -> slot
  | None ->
    let res = get_and_incr_num_stack_slots state (Proc.register_class reg) in
    Reg.Tbl.add state.stack_slots reg res;
    res

let[@inline] num_stack_slots state = state.num_stack_slots

let[@inline] get_and_incr_instruction_id state =
  let res = state.next_instruction_id in
  state.next_instruction_id <- succ res;
  res

let[@inline] add_introduced_temporaries_one state reg =
  state.introduced_temporaries <- Reg.Set.add reg state.introduced_temporaries

let[@inline] add_introduced_temporaries_list state regs =
  state.introduced_temporaries
    <- List.fold_left regs ~init:state.introduced_temporaries
         ~f:(fun introduced reg -> Reg.Set.add reg introduced)

let[@inline] mem_introduced_temporaries state reg =
  Reg.Set.mem reg state.introduced_temporaries

let[@inline] introduced_temporaries state = state.introduced_temporaries

let[@inline] check_disjoint sets ~is_disjoint =
  List.iter sets ~f:(fun (name1, set1) ->
      List.iter sets ~f:(fun (name2, set2) ->
          if name1 < name2
          then
            if not (is_disjoint set1 set2)
            then fatal "sets %s and %s are not disjoint" name1 name2))

let[@inline] check_set_and_field_consistency_reg (work_list, set, field_value) =
  Reg.Set.iter
    (fun reg ->
      if reg.Reg.irc_work_list <> field_value
      then
        fatal "register %a is in %s but its field equals %S" Printmach.reg reg
          work_list
          (Reg.string_of_irc_work_list reg.Reg.irc_work_list))
    set

let[@inline] check_set_and_field_consistency_instr (work_list, set, field_value)
    =
  Instruction.Set.iter
    (fun instr ->
      if instr.Cfg.irc_work_list <> field_value
      then
        fatal "instruction %d is in %s but its field equals %S" instr.Cfg.id
          work_list
          (Cfg.string_of_irc_work_list instr.Cfg.irc_work_list))
    set

let[@inline] check_inter_has_no_duplicates (reg : Reg.t) : unit =
  let l = reg.Reg.interf in
  let s = Reg.Set.of_list l in
  if List.length l <> Reg.Set.cardinal s
  then fatal "interf list for %a is not a set" Printmach.reg reg

let[@inline] invariant state =
  (* CR xclerc for xclerc: avoid multiple conversions to sets. *)
  if irc_debug && irc_invariants
  then (
    (* interf (list) is morally a set *)
    List.iter (Reg.all_registers ()) ~f:check_inter_has_no_duplicates;
    Array.iter all_precolored_regs ~f:check_inter_has_no_duplicates;
    (* register sets are disjoint *)
    check_disjoint ~is_disjoint:Reg.Set.disjoint
      [ "precolored", Reg.set_of_array all_precolored_regs;
        "initial", Reg.Set.of_list state.initial;
        "simplify_work_list", RegWorkList.to_set state.simplify_work_list;
        "freeze_work_list", RegWorkList.to_set state.freeze_work_list;
        "spill_work_list", RegWorkList.to_set state.spill_work_list;
        "spilled_nodes", RegWorkList.to_set state.spilled_nodes;
        "coalesced_nodes", RegWorkList.to_set state.coalesced_nodes;
        "colored_nodes", Reg.Set.of_list state.colored_nodes;
        "select_stack", Reg.Set.of_list state.select_stack ];
    List.iter ~f:check_set_and_field_consistency_reg
      [ "precolored", Reg.set_of_array all_precolored_regs, Reg.Precolored;
        "initial", Reg.Set.of_list state.initial, Reg.Initial;
        ( "simplify_work_list",
          RegWorkList.to_set state.simplify_work_list,
          Reg.Simplify );
        ( "freeze_work_list",
          RegWorkList.to_set state.freeze_work_list,
          Reg.Freeze );
        "spill_work_list", RegWorkList.to_set state.spill_work_list, Reg.Spill;
        "spilled_nodes", RegWorkList.to_set state.spilled_nodes, Reg.Spilled;
        ( "coalesced_nodes",
          RegWorkList.to_set state.coalesced_nodes,
          Reg.Coalesced );
        "colored_nodes", Reg.Set.of_list state.colored_nodes, Reg.Colored;
        "select_stack", Reg.Set.of_list state.select_stack, Reg.Select_stack ];
    (* move sets are disjoint *)
    check_disjoint ~is_disjoint:Instruction.Set.disjoint
      [ "coalesced_moves", InstructionWorkList.to_set state.coalesced_moves;
        "constrained_moves", InstructionWorkList.to_set state.constrained_moves;
        "frozen_moves", InstructionWorkList.to_set state.frozen_moves;
        "work_list_moves", InstructionWorkList.to_set state.work_list_moves;
        "active_moves", InstructionWorkList.to_set state.active_moves ];
    List.iter ~f:check_set_and_field_consistency_instr
      [ ( "coalesced_moves",
          InstructionWorkList.to_set state.coalesced_moves,
          Cfg.Coalesced );
        ( "constrained_moves",
          InstructionWorkList.to_set state.constrained_moves,
          Cfg.Constrained );
        ( "frozen_moves",
          InstructionWorkList.to_set state.frozen_moves,
          Cfg.Frozen );
        ( "work_list_moves",
          InstructionWorkList.to_set state.work_list_moves,
          Cfg.Work_list );
        ( "active_moves",
          InstructionWorkList.to_set state.active_moves,
          Cfg.Active ) ];
    (* degree is consistent with adjacency lists/sets *)
    let work_lists =
      Reg.Set.union
        (RegWorkList.to_set state.simplify_work_list)
        (Reg.Set.union
           (RegWorkList.to_set state.freeze_work_list)
           (RegWorkList.to_set state.spill_work_list))
    in
    let work_lists_or_precolored =
      Reg.Set.union (Reg.set_of_array all_precolored_regs) work_lists
    in
    Reg.Set.iter
      (fun u ->
        let degree = u.Reg.degree in
        if degree = Degree.infinite
        then fatal "invariant: infinite degree for %a" Printmach.reg u
        else
          let adj_list = Reg.Set.of_list (adj_list state u) in
          let cardinal =
            Reg.Set.cardinal (Reg.Set.inter adj_list work_lists_or_precolored)
          in
          if not (Int.equal degree cardinal)
          then (
            List.iter u.Reg.interf ~f:(fun r ->
                log ~indent:0 "%a <- interf[%a]" Printmach.reg r Printmach.reg u);
            Reg.Set.iter
              (fun r ->
                log ~indent:0 "%a <- adj_list[%a]" Printmach.reg r Printmach.reg
                  u)
              adj_list;
            Reg.Set.iter
              (fun r ->
                log ~indent:0 "%a <- work_lists_or_precolored[%a]" Printmach.reg
                  r Printmach.reg u)
              (Reg.Set.inter adj_list work_lists_or_precolored);
            fatal
              "invariant expected degree for %a to be %d but got %d\n\
              \ (#adj_list=%d, #work_lists_or_precolored=%d)" Printmach.reg u
              cardinal degree
              (Reg.Set.cardinal adj_list)
              (Reg.Set.cardinal work_lists_or_precolored)))
      work_lists)
