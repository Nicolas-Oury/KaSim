(**
  * cflow_handler.ml
  *
  * Causal flow compression: a module for KaSim 
  * Jérôme Feret, projet Abstraction, INRIA Paris-Rocquencourt
  * Jean Krivine, Université Paris-Diderot, CNRS 
  * 
  * KaSim
  * Jean Krivine, Université Paris Dederot, CNRS 
  *  
  * Creation: 29/08/2011
  * Last modification: 02/07/2012
  * * 
  * Some parameter references can be tuned thanks to command-line options
  * other variables has to be set before compilation   
  *  
  * Copyright 2011,2012 Institut National de Recherche en Informatique et   
  * en Automatique.  All rights reserved.  This file is distributed     
  * under the terms of the GNU Library General Public License *)

module type PreBlackboard = 
sig 
  module A:LargeArray.GenArray
  module CI:Pseudo_inverse.Cut_pseudo_inverse 

  type step_id = int 
  type step_short_id = int 

  (** blackboard predicates*)

  type predicate_id = int
  type predicate_info
  type predicate_value 
 
  module C:(Cache.Cache with type O.t = predicate_value)  


  type pre_blackboard  (*blackboard during its construction*)

  val weakening: predicate_value -> predicate_value list 
  val conj: (predicate_value -> predicate_value -> CI.Po.K.H.error_channel * predicate_value) CI.Po.K.H.with_handler
  val disjunction: (predicate_value -> predicate_value -> CI.Po.K.H.error_channel * predicate_value) CI.Po.K.H.with_handler  
 
  val defined: predicate_value
  val undefined: predicate_value 
  val unknown: predicate_value
  val is_unknown: predicate_value -> bool 
  val is_undefined: predicate_value -> bool 
  val more_refined: predicate_value -> predicate_value -> bool 
  val compatible: predicate_value -> predicate_value -> bool 
  val strictly_more_refined: predicate_value -> predicate_value -> bool 
  val get_pre_column_map_inv: pre_blackboard -> predicate_info A.t
  (** generation*)
  val init:  ((*CI.Po.K.P.log_info ->*) CI.Po.K.H.error_channel * pre_blackboard) CI.Po.K.H.with_handler 
  val add_step: (CI.Po.K.P.log_info -> CI.Po.K.refined_step -> pre_blackboard -> CI.Po.K.H.error_channel * CI.Po.K.P.log_info * pre_blackboard) CI.Po.K.H.with_handler
  val finalize: (CI.Po.K.P.log_info -> pre_blackboard -> CI.Po.K.H.error_channel * CI.Po.K.P.log_info * pre_blackboard) CI.Po.K.H.with_handler 

  (**pretty printing*)
  val print_predicate_value: out_channel ->  predicate_value -> unit 
  val print_preblackboard: (pre_blackboard -> CI.Po.K.H.error_channel) CI.Po.K.H.with_handler  

  (**interface*)
  val n_events: (pre_blackboard -> CI.Po.K.H.error_channel * int) CI.Po.K.H.with_handler 
  val n_predicates: (pre_blackboard -> CI.Po.K.H.error_channel * int) CI.Po.K.H.with_handler 
  val n_events_per_predicate: (pre_blackboard -> predicate_id -> CI.Po.K.H.error_channel * int) CI.Po.K.H.with_handler 
  val event_list_of_predicate: (pre_blackboard -> predicate_id -> CI.Po.K.H.error_channel * (int * int * predicate_value * predicate_value ) list) CI.Po.K.H.with_handler 
  val mandatory_events: (pre_blackboard -> CI.Po.K.H.error_channel * ((int list * unit Mods.simulation_info option) list)) CI.Po.K.H.with_handler 
  val get_pre_event: (pre_blackboard -> CI.Po.K.H.error_channel * CI.Po.K.refined_step A.t) CI.Po.K.H.with_handler 
  val get_side_effect: (pre_blackboard -> CI.Po.K.H.error_channel * CI.Po.K.side_effect A.t) CI.Po.K.H.with_handler 
  val get_fictitious_observable: (pre_blackboard -> CI.Po.K.H.error_channel * int option) CI.Po.K.H.with_handler 
end

module Preblackboard = 
  (struct 

     (** Useful modules *)
     module H = Cflow_handler.Cflow_handler
     module A = Mods.DynArray
     module CI = Pseudo_inverse.Pseudo_inv

     (** blackboard matrix*) 

     type step_id = int       (** global id of an event *)
     type step_short_id = int (** position of an event on a wire *)

     (** blackboard predicates*)

     type rule_type = (** kind of events*)
       | Dummy 
       | Init 
       | Observable
       | Rule 
       | Side_effect_of of (step_id * (CI.Po.K.agent_id * CI.Po.K.site_name) list)
     
     type predicate_id = int (** wire identifiers *)
     type predicate_info = (** wire labels *)
       | Here of CI.Po.K.agent_id  
       | Bound_site of CI.Po.K.agent_id * CI.Po.K.site_name
       | Internal_state of CI.Po.K.agent_id * CI.Po.K.site_name 
       | Fictitious of int (**to handle with ambiguous site effects *)

     type predicate_value = 
       | Counter of int 
       | Internal_state_is of CI.Po.K.internal_state
       | Defined   (** the wire does exist, but we do not know what the value is *)
       | Undefined (** the wire does not exist yet *)
       | Present   (** for agent presence *)
       | Free      (** for binding sites *)
       | Bound     (** for binding sites (partial information) *)
       | Bound_to of predicate_id * CI.Po.K.agent_id * CI.Po.K.agent_name * CI.Po.K.site_name
           (** for bindinf sites (complete information) *)
       | Bound_to_type of CI.Po.K.agent_name * CI.Po.K.site_name (** for binding sites (partial information *)
       | Unknown (**  for agent presence, internal states, binding states (partial information *) 

     module C = (Cache.Cache(struct type t = predicate_value let compare = compare end):Cache.Cache with type O.t = predicate_value) 

     let weakening p = 
       match p 
       with 
         | Counter _ | Internal_state_is _ | Present | Free | Bound  -> [p;Defined]
         | Bound_to (_,_,ag,site) -> [p;Bound_to_type (ag,site);Bound;Defined]
         | Bound_to_type _ -> [p;Bound;Defined]
         | Defined | Undefined -> [p]
         | Unknown -> []

     let defined = Defined 
     let undefined = Undefined 
     let unknown = Unknown 
     let is_unknown x = x=Unknown 
     let is_undefined x = x=Undefined 

     (** maps and sets *)
     module PredicateMap = Map.Make (struct type t = predicate_info let compare = compare end)
     module PredicateSet = Set.Make (struct type t = predicate_info let compare = compare end)
     module CaseValueSet = Set.Make (struct type t = predicate_value let compare = compare end)
     module PredicateidSet = Set.Make (struct type t = predicate_id let compare = compare end)
     module PredicateidMap = Map.Make (struct type t = predicate_id let compare = compare end)
     module SidMap = Map.Make (struct type t = step_id let compare = compare end)
           
     type pre_blackboard = 
	 {
           pre_fictitious_list: predicate_id list ; (** list of wire for mutual exclusions, the state must be undefined at the end of the trace *) 
           pre_steps_by_column: (step_short_id * (step_id * step_short_id * predicate_value * predicate_value) list) A.t; (** maps each wire to the last known value and the list of step (step id,test,action)*)
           pre_kind_of_event: rule_type A.t; (** maps each event id to the kind of event *)
           pre_event: CI.Po.K.refined_step A.t; (** maps each event to the step *)
	   pre_nsteps: step_id; (**id of the last event *)
	   pre_ncolumn: predicate_id; (**id of the last wire *)
	   pre_column_map: predicate_id PredicateMap.t; (** maps each wire label to its wire id *)
	   pre_column_map_inv: predicate_info A.t; (** maps each wire id to its wire label *)
	   predicate_id_list_related_to_predicate_id: PredicateidSet.t A.t; (** maps each wire id for the presence of an agent to the set of wires for its attibute (useful, when an agent get removed, all its attributes get undefined *)
           history_of_predicate_values_to_predicate_id: C.t A.t; (* maps each wire to the set of its previous states, this summarize the potential state of a site that is freed, so as to overapproximate the set of potential side effects*)
           pre_observable_list: (step_id list * unit Mods.simulation_info option) list ;
           pre_side_effect_of_event: CI.Po.K.side_effect A.t;
           pre_fictitious_observable: step_id option; (*id of the step that closes all the side-effect mutex *) 
           
           } 

         let get_pre_column_map_inv x = x.pre_column_map_inv 
         let get_pre_event parameter handler error x = error,x.pre_event 
           
         (** pretty printing *)
         let print_predicate_info log x = 
           match x 
           with 
         | Here i -> Printf.fprintf log "Agent_Here %i \n" i
         | Bound_site (i,s) -> Printf.fprintf log "Binding_state (%i,%i) \n" i s 
         | Internal_state (i,s) -> Printf.fprintf log "Internal_state (%i,%i) \n" i s 
         | Fictitious (int) -> Printf.fprintf log "Fictitious %i \n" int 
           
         let print_known log t x = 
           match t
           with 
             | Unknown -> ()
             | _ -> Printf.fprintf log "%s" x
               
         let print_predicate_value log x = 
           match x 
           with 
             | Counter int ->  
               Printf.fprintf log "Counter %i" int
             | Defined -> 
               Printf.fprintf log "Defined" 
             | Internal_state_is internal_state -> 
               Printf.fprintf log "%i" internal_state  
             | Undefined -> 
               Printf.fprintf log "Undefined"
             | Present ->
               Printf.fprintf log "Present"
             | Free -> 
               Printf.fprintf log "Free" 
             | Bound -> 
               Printf.fprintf log "Bound" 
             | Bound_to (id,agent_id,agent_name,site) ->
               Printf.fprintf log "Bound(%i,%i(%i)@%i)" id agent_id agent_name site
             | Bound_to_type (agent,site)-> 
               Printf.fprintf log "Bound(%i@%i)" agent site 
             | Unknown -> ()
               
         let print_predicate_id log blackboard i = 
           let predicate_info = A.get blackboard.pre_column_map_inv i in  
           let _ = Printf.fprintf log "Predicate: %i " i in 
           let _ = print_predicate_info log predicate_info in 
           ()
             
         let print_preblackboard parameter handler error blackboard = 
           let log = parameter.CI.Po.K.H.out_channel in 
           let _ = Printf.fprintf log "**\nPREBLACKBOARD\n**\n" in 
           let _ = Printf.fprintf log "*\n steps by column\n*\n" in 
           let _ = 
             A.iteri 
               (fun id (nevents,list) ->
                 let _ = print_predicate_id log blackboard id  in
                 let _ = Printf.fprintf log "nevents: %i \n" nevents in 
                 let _ = 
                   List.iter 
                     (fun (eid,seid,test,action) -> 
                       let _ = Printf.fprintf log "Event id: %i \n" eid in 
                       let _ = Printf.fprintf log "Short id: %i \n" seid in 
                       let _ = print_known log test "TEST:   " in
                       let _ = print_predicate_value log test in 
                       let _ = Printf.fprintf log "\n" in 
                       let _ = print_known log action "ACTION: " in 
                       let _ = print_predicate_value log action in 
                       let _ = Printf.fprintf log "\n" in 
                       ())
                     (List.rev list)
                 in 
                 let _ = Printf.fprintf log "---\n" in 
                 ())
               blackboard.pre_steps_by_column 
           in 
           let _ = Printf.fprintf log "*\nSide effects \n*\n" in 
           let _ = A.iteri 
             (fun i list -> 
               let _ = Printf.fprintf log "event %i:\n " i in
               let _ = CI.Po.K.print_side_effect log list in 
               let _ = Printf.fprintf log "\n" in 
               ()
             )
             blackboard.pre_side_effect_of_event 
           in 
           let _ = Printf.fprintf log "*\nPredicate_id related to the predicate \n*\n" in 
           
           let _ = 
             A.iteri 
               (fun i s -> 
                 let _ = print_predicate_id log blackboard i in 
                 let _ = 
                   PredicateidSet.iter
                     (fun s -> Printf.fprintf log "%i\n" s)
                     s
                 in 
                 let _ = Printf.fprintf log "---\n" in 
                 ()
               )
               blackboard.predicate_id_list_related_to_predicate_id 
           in 
           let _ = Printf.fprintf log "*\nPast values of a predicate \n*\n" in 
           let _ = 
             A.iteri 
               (fun i s -> 
                 let _ = print_predicate_id log blackboard i in 
                 let _ = 
                   C.iter 
                     (fun s -> print_predicate_value log s)
                     s
                 in 
                 let _ = Printf.fprintf log "---\n" in 
                 ()
               )
               blackboard.history_of_predicate_values_to_predicate_id 
           in 
           let _ = Printf.fprintf log "*\nObservables \n*\n" in
           let _ = 
             List.iter 
               (fun (l,_) -> 
                 let _ = List.iter (Printf.fprintf log "%i,") l in 
                 let _ = Printf.fprintf log "\n" in 
                 () 
               )
               blackboard.pre_observable_list 
           in 
           
           let _ = Printf.fprintf log "**\n" in 
           error 
             
     (** information lattice *)
         let strictly_more_refined x y = 
           match y  
           with 
             | Undefined 
             | Counter _ 
             | Internal_state_is _ 
             | Present 
             | Free 
             | Bound_to (_) -> false
             | Bound_to_type (ag,s) -> 
               begin 
                 match x 
                 with 
                   | Bound_to(_,_,ag',s') when ag=ag' && s=s' -> true
                   | _ -> false 
               end
             | Bound -> 
               begin
                 match x 
                 with 
                   | Bound_to _ | Bound_to_type _ -> true
                   | _ -> false
               end
             | Defined -> 
               begin
                 match x 
                 with
                   | Unknown | Defined | Undefined -> false
                   | _ -> true
               end 
             | Unknown -> 
               begin
                 match x
                 with 
                   | Unknown -> false
                   | _ -> true 
               end
                 
         let more_refined x y = x=y or strictly_more_refined x y
           
         let conj parameter handler error x y = 
           if more_refined x y then error,x 
           else 
             if strictly_more_refined y x then error,y 
             else 
               let error_list,error = CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "conj") (Some "323") (Some "Arguments have no greatest lower bound") (failwith "Arguments have no greatest lower bound")  in 
               CI.Po.K.H.raise_error parameter handler error_list error Undefined  
                 
         let compatible x y = 
           x=y or more_refined x y or more_refined y x
           
         let disjunction parameter handler error x y = 
           error,
           if x=y then x 
           else 
             match x,y
             with
               | Unknown,_ | _,Unknown | Undefined,_ | _,Undefined -> Unknown 
               | Defined,_ | _,Defined -> Defined
               | Counter _,_ | _,Counter _ | Free,_ | _,Free | Present,_ | _,Present | Internal_state_is _,_ |_,Internal_state_is _ -> Defined 
               | Bound,_ | _,Bound -> Bound 
               | Bound_to_type (a,b), Bound_to (_,_,c,d)
               | Bound_to (_,_,a,b),Bound_to (_,_,c,d)
               | Bound_to (_,_,a,b),Bound_to_type (c,d) when a=c && b=d -> Bound_to_type(a,b)  
               | _ -> Bound 
                 
     (** predicate id allocation *)
                 
     (** if a wire concerns an agent, which one it is *)
         let agent_id_of_predicate x =  
           match x 
           with 
             | Here x -> Some x 
             | Bound_site (x,_) -> Some x 
             | Internal_state (x,_) -> Some x 
             | Fictitious _ -> None 
               
               
         let rec bind parameter handler error blackboard predicate predicate_id ag_id =
           let error,blackboard,sid = allocate parameter handler error blackboard (Here ag_id)
           in 
           let old_set = 
             try 
               A.get blackboard.predicate_id_list_related_to_predicate_id sid
             with 
                 Not_found -> 
                   PredicateidSet.empty
           in 
           let new_set = 
             PredicateidSet.add predicate_id old_set 
           in 
           try 
             let _ = A.set blackboard.predicate_id_list_related_to_predicate_id sid new_set in 
             error,blackboard 
           with 
               Not_found ->
                 let error_list,error = 
                   CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "bind") (Some "375") (Some "Out of bound access") (failwith "bind") in 
                 CI.Po.K.H.raise_error parameter handler error_list error blackboard 
         and 
             allocate parameter handler error blackboard predicate  = 
           let ag_id = agent_id_of_predicate predicate in 
           let map = blackboard.pre_column_map in 
           let map_inv = blackboard.pre_column_map_inv in 
           try 
             let sid = PredicateMap.find predicate map in
             error,blackboard,sid
           with 
             | Not_found -> 
               let sid'= blackboard.pre_ncolumn + 1 in 
               let map' = PredicateMap.add predicate sid' map in 
               let _  = A.set map_inv sid' predicate in 
               let map_inv' = map_inv in 
               let _ = A.set blackboard.history_of_predicate_values_to_predicate_id sid' (C.create parameter.CI.Po.K.H.cache_size) in 
               let blackboard = 
                 {blackboard 
                  with 
                    pre_ncolumn = sid' ; 
                    pre_column_map = map' ;
                    pre_column_map_inv = map_inv' 
                 }
               in 
               let error,blackboard = 
                 match ag_id 
                 with 
                   | None -> 
                     error, blackboard 
                   | Some ag_id -> 
                     bind parameter handler error blackboard predicate sid' ag_id 
               in 
               error,blackboard,sid' 
                 
         let free_agent parameter handler error blackboard agent_id = 
           let error,blackboard,predicate_id = 
             allocate parameter handler error blackboard (Here agent_id)  in 
           let error,set = 
             try 
               error,A.get blackboard.predicate_id_list_related_to_predicate_id predicate_id
             with 
               | _ -> 
                 let error_list,error = 
                   CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "free_agent") (Some "418") (Some "Try to free an unexisting agent") (failwith "free_agent") in 
                 CI.Po.K.H.raise_error parameter handler error_list error PredicateidSet.empty 
           in 
           let map = 
             PredicateidSet.fold 
               (fun predicate_id map -> 
                 let predicate = A.get blackboard.pre_column_map_inv predicate_id in 
                 PredicateMap.remove predicate map
               )
               set 
               blackboard.pre_column_map
           in 
           error,{blackboard with pre_column_map = map}
         
         let free_agent_if_it_exists parameter handler error blackboard agent_id = 
           try 
             let _ = PredicateMap.find (Here agent_id) blackboard.pre_column_map in
             free_agent parameter handler error blackboard agent_id 
           with 
             | _ -> error,blackboard 
             
         let predicates_of_action parameter handler error blackboard init action = 
           match action with 
             | CI.Po.K.Create (ag,interface) -> 
               let ag_id = CI.Po.K.agent_id_of_agent ag in
               let error,blackboard = 
                 if init 
                 then 
                   error,blackboard
                 else 
                   free_agent_if_it_exists parameter handler error blackboard ag_id in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Here ag_id) in   
               List.fold_left 
                 (fun (error,blackboard,list1,list2) (s_id,opt) -> 
                   let error,blackboard,predicate_id = allocate parameter handler error blackboard (Bound_site(ag_id,s_id)) in 
                   let list1 = (predicate_id,Free)::list1 in
                   let list2 = (predicate_id,Undefined)::list2 in 
                   match opt 
                   with 
                     | None -> error,blackboard,list1,list2
                     | Some x -> 
                       let error,blackboard,predicate_id = allocate parameter handler error blackboard (Internal_state (ag_id,s_id)) in 
                       error,
                       blackboard,
                       (predicate_id,Internal_state_is x)::list1,
                       (predicate_id,Undefined)::list2
                 )
                 (error,blackboard,[predicate_id,Present],[predicate_id,Undefined])
                 interface
             | CI.Po.K.Mod_internal (site,int)  -> 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Internal_state (CI.Po.K.agent_id_of_site site,CI.Po.K.site_name_of_site site)) in 
               error,blackboard,[predicate_id,Internal_state_is int],[]
             | CI.Po.K.Bind_to (s1,s2) -> 
               let ag_id1 = CI.Po.K.agent_id_of_site s1 in 
               let ag_id2 = CI.Po.K.agent_id_of_site s2 in 
               let agent_name2 = CI.Po.K.agent_name_of_site s2 in 
               let site_id1 = CI.Po.K.site_name_of_site s1 in 
               let site_id2 = CI.Po.K.site_name_of_site s2 in 
               let error,blackboard,predicate_id1 = allocate parameter handler error blackboard (Bound_site (ag_id1,site_id1)) in 
               let error,blackboard,predicate_id2 = allocate parameter handler error blackboard (Bound_site (ag_id2,site_id2)) in 
               error,blackboard,
               [predicate_id1,Bound_to (predicate_id2,ag_id2,agent_name2,site_id2)],[]
             | CI.Po.K.Bind (s1,s2) -> 
               let ag_id1 = CI.Po.K.agent_id_of_site s1 in 
               let ag_id2 = CI.Po.K.agent_id_of_site s2 in 
               let agent_name1 = CI.Po.K.agent_name_of_site s1 in 
               let agent_name2 = CI.Po.K.agent_name_of_site s2 in 
               let site_id1 = CI.Po.K.site_name_of_site s1 in 
               let site_id2 = CI.Po.K.site_name_of_site s2 in 
               let error,blackboard,predicate_id1 = allocate parameter handler error blackboard (Bound_site (ag_id1,site_id1)) in 
               let error,blackboard,predicate_id2 = allocate parameter handler error blackboard (Bound_site (ag_id2,site_id2)) in 
               error,blackboard,
               [predicate_id1,Bound_to (predicate_id2,ag_id2,agent_name2,site_id2);
                predicate_id2,Bound_to (predicate_id1,ag_id1,agent_name1,site_id1)],[]
             | CI.Po.K.Unbind (s1,s2) ->
               let ag_id1 = CI.Po.K.agent_id_of_site s1 in 
               let ag_id2 = CI.Po.K.agent_id_of_site s2 in 
               let site_id1 = CI.Po.K.site_name_of_site s1 in 
               let site_id2 = CI.Po.K.site_name_of_site s2 in 
               let error,blackboard,predicate_id1 = allocate parameter handler error blackboard (Bound_site (ag_id1,site_id1)) in 
               let error,blackboard,predicate_id2 = allocate parameter handler error blackboard (Bound_site (ag_id2,site_id2)) in 
               error,blackboard,[predicate_id1,Free;predicate_id2,Free],[]
             | CI.Po.K.Free s -> 
               let ag_id = CI.Po.K.agent_id_of_site s in 
               let site_id = CI.Po.K.site_name_of_site s in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Bound_site (ag_id,site_id)) in     
               error,blackboard,[predicate_id,Free],[]
             | CI.Po.K.Remove ag -> 
               let ag_id = CI.Po.K.agent_id_of_agent ag in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Here ag_id) in 
               let error,blackboard = free_agent parameter handler error blackboard ag_id in 
               let set = 
                 A.get 
                   blackboard.predicate_id_list_related_to_predicate_id
                   predicate_id 
               in 
               let error,blackboard,list = 
                 PredicateidSet.fold 
                   (fun predicateid (error,blackboard,list) -> 
                     error,blackboard,(predicateid,Undefined)::list)
                   set 
                   (error,blackboard,[predicate_id,Undefined]) 
               in   
               error,blackboard,list,[]
                 
         let predicates_of_test  parameter handler error blackboard test = 
           match test
           with 
             | CI.Po.K.Is_Here (agent) ->
               let ag_id = CI.Po.K.agent_id_of_agent agent in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Here ag_id) in 
               error,blackboard,[predicate_id,Present]
             | CI.Po.K.Has_Internal(site,int) -> 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Internal_state (CI.Po.K.agent_id_of_site site,CI.Po.K.site_name_of_site site)) in 
               error,blackboard,[predicate_id,Internal_state_is int]
             | CI.Po.K.Is_Free s -> 
               let ag_id = CI.Po.K.agent_id_of_site s in 
               let site_id = CI.Po.K.site_name_of_site s in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Bound_site (ag_id,site_id)) in     
               error,blackboard,[predicate_id,Free]
             | CI.Po.K.Is_Bound_to  (s1,s2) -> 
               let ag_id1 = CI.Po.K.agent_id_of_site s1 in 
               let ag_id2 = CI.Po.K.agent_id_of_site s2 in 
               let agent_name1 = CI.Po.K.agent_name_of_site s1 in 
               let agent_name2 = CI.Po.K.agent_name_of_site s2 in 
               let site_id1 = CI.Po.K.site_name_of_site s1 in 
               let site_id2 = CI.Po.K.site_name_of_site s2 in 
               let error,blackboard,predicate_id1 = allocate parameter handler error blackboard (Bound_site (ag_id1,site_id1)) in 
               let error,blackboard,predicate_id2 = allocate parameter handler error blackboard (Bound_site (ag_id2,site_id2)) in 
               error,blackboard,
               [predicate_id1,Bound_to (predicate_id2,ag_id2,agent_name2,site_id2);
                predicate_id2,Bound_to (predicate_id1,ag_id1,agent_name1,site_id1)]
             | CI.Po.K.Is_Bound s -> 
               let ag_id = CI.Po.K.agent_id_of_site s in 
               let site_id = CI.Po.K.site_name_of_site s in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Bound_site (ag_id,site_id)) in 
               error,blackboard,
               [predicate_id,Bound]   
             | CI.Po.K.Has_Binding_type (s,btype) ->
               let ag_id = CI.Po.K.agent_id_of_site s in 
               let site_id = CI.Po.K.site_name_of_site s in
               let agent_name = CI.Po.K.agent_of_binding_type btype in 
               let site_name = CI.Po.K.site_of_binding_type btype in 
               let error,blackboard,predicate_id = allocate parameter handler error blackboard (Bound_site (ag_id,site_id)) in 
               error,blackboard,
               [predicate_id,Bound_to_type (agent_name,site_name)]
                 
         let type_of_step x = 
           match x 
           with 
             | CI.Po.K.Dummy -> Dummy 
             | CI.Po.K.Init _ -> Init 
             | CI.Po.K.Event _ -> Rule 
             | CI.Po.K.Obs _ -> Observable
               
  (** initialisation*)
         let init parameter handler error (*log_info*) = 
           error, 
           {
             pre_side_effect_of_event = A.make 1 CI.Po.K.empty_side_effect;
             pre_event = A.make 1 CI.Po.K.dummy_refined_step;
             pre_fictitious_list = [] ; 
             pre_steps_by_column = A.make 1 (1,[]) ; 
             pre_nsteps = -1 ;
             pre_ncolumn = -1 ;
             pre_column_map = PredicateMap.empty ; 
             pre_column_map_inv = A.make 1 (Fictitious 0) ; 
             pre_kind_of_event = A.make 1 (Side_effect_of (-1,[])) ;
             history_of_predicate_values_to_predicate_id = A.make 1 (C.create None);
             predicate_id_list_related_to_predicate_id = A.make 1 PredicateidSet.empty;
             pre_observable_list = [];
             pre_fictitious_observable = None ;
           }
    
         let pre_column_map_inv b = b.pre_column_map_inv 
           
         let init_fictitious_action log_info error predicate_id blackboard = 
           let nsid = blackboard.pre_nsteps+1 in 
           let log_info = CI.Po.K.P.inc_n_side_events log_info in 
           let test = Undefined in 
           let action = Counter 0 in
           let _ = A.set blackboard.pre_steps_by_column predicate_id (2,[nsid,1,test,action])  in 
           error,log_info,{blackboard with pre_nsteps = nsid} 
             
         let add_fictitious_action error test action predicate_id blackboard = 
           let nsid = blackboard.pre_nsteps in 
           let map = blackboard.pre_steps_by_column in 
           let value,list = A.get map predicate_id in 
           let value' = value+1 in
           let _ = A.set map predicate_id (value',(nsid,value,test,action)::list) in 
           error,blackboard
             
         let side_effect parameter handler error predicate_target_id s site = 
           match s 
           with 
             | Defined | Counter _ | Internal_state_is _ | Undefined 
             | Present | Bound | Bound_to_type _ | Unknown -> 
               let error,error_list = 
                 CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "side_effects") (Some "602") (Some "Illegal state for a side-effects") (failwith "Blackboard_generation.side_effect") in 
               CI.Po.K.H.raise_error parameter handler error error_list []
             | Free -> 
               error,[predicate_target_id,None,(Free,Unknown)]
             | Bound_to (pid,ag,_,sname) -> 
               error,[predicate_target_id,None,(s,Unknown);
                      pid,Some (ag,sname),(Bound_to (predicate_target_id,CI.Po.K.agent_id_of_site site,CI.Po.K.agent_name_of_site site,CI.Po.K.site_name_of_site site),Free)]
                 
                 
         let predicate_value_of_binding_state parameter handler error x = 
           match x 
           with 
             | CI.Po.K.ANY -> error,Unknown 
             | CI.Po.K.FREE -> error,Free
             | CI.Po.K.BOUND -> error,Bound
             | CI.Po.K.BOUND_TYPE bt -> error,Bound_to_type (CI.Po.K.agent_name_of_binding_type bt,CI.Po.K.site_name_of_binding_type bt)
             | CI.Po.K.BOUND_to s -> 
               let error_list,error = 
                 CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "predicate_value_of_binding_state") (Some "620") (Some "Illegal binding state in predicate_value_of_binding_state") (failwith "predicate_value_of_binding_state") in 
               CI.Po.K.H.raise_error parameter handler error_list error Unknown 
                 
         let potential_target error parameter handler blackboard site binding_state =
           let agent_id = CI.Po.K.agent_id_of_site site in 
           let site_name = CI.Po.K.site_name_of_site site in 
           let error,balckboard,predicate_target_id = 
             allocate parameter handler error blackboard (Bound_site (agent_id,site_name))  in 
           let former_states = 
             A.get blackboard.history_of_predicate_values_to_predicate_id predicate_target_id
           in 
           if Parameter.get_causal_trace_only parameter.CI.Po.K.H.compression_mode 
           then 
             begin 
               let s = C.last former_states in 
               match s with 
                 | None -> error,blackboard,[]
                 | Some s -> 
                   let error,bt = predicate_value_of_binding_state parameter handler error binding_state in
                   if more_refined s bt 
                   then 
                     let error,l=side_effect parameter handler error predicate_target_id s site in 
                     error,blackboard,[l]
                   else 
                     error,blackboard,[]
             end
           else 
             begin 
               let error,bt = predicate_value_of_binding_state parameter handler error binding_state in 
               let error,list = 
                 C.fold 
                   (fun s (error,list) -> 
                     if more_refined s bt
                     then 
                       let error,l=side_effect parameter handler error predicate_target_id s site in 
                       error,l::list 
                     else 
                       error,list
                   )
                   former_states
                   (error,[])
               in 
               error,blackboard,list 
             end 
               
         let add_step parameter handler error log_info step blackboard = 
           let init = CI.Po.K.is_init_of_refined_step step in 
           let pre_event = blackboard.pre_event in 
           let test_list = CI.Po.K.tests_of_refined_step step in 
           let action_list,side_effect = CI.Po.K.actions_of_refined_step step in
           let action_list = action_list in 
           let fictitious_local_list = [] in 
           let fictitious_list = blackboard.pre_fictitious_list in 
           let build_map list map = 
             List.fold_left 
               (fun map (id,value) -> PredicateidMap.add id value map)
               map 
               list 
           in 
           let add_state pid (test,action) map = 
             let test',action' = 
               try 
                 PredicateidMap.find pid map  
               with 
                 | Not_found -> Unknown,Unknown 
             in 
             let test = 
               if strictly_more_refined test test' 
               then 
                 test
               else 
                 test'
             in 
             let action = 
               if strictly_more_refined action action' 
               then 
                 action
               else 
                 action'
             in 
             let map = PredicateidMap.add pid (test,action) map in 
             map 
           in 
           let fadd pid p map = 
             match p 
             with 
               | Counter _ | Internal_state_is _ | Undefined 
               | Defined | Present | Bound | Bound_to_type _ | Unknown -> 
                 ()
               | _ -> 
                 let old = A.get map pid in 
                 A.set map pid (C.add p old) 
           in 
           let error,blackboard,fictitious_list,fictitious_local_list,unambiguous_side_effects = 
             List.fold_left 
               (fun (error,blackboard,fictitious_list,fictitious_local_list,unambiguous_side_effects) (site,(binding_state)) -> 
                 begin
                   let error,blackboard,potential_target = potential_target error parameter handler blackboard site binding_state in 
                   match 
                     potential_target 
                   with 
                     | [l]  ->  
                       begin
                         let list = 
                           List.fold_left 
                             (fun list t -> t::l)
                             unambiguous_side_effects
                             l 
                         in 
                         error,
                         blackboard,
                         fictitious_list,
                         fictitious_local_list,
                         list 
                       end
                     | _ -> 
                       begin 
                         let nsid = blackboard.pre_nsteps + 1 in 
                         let predicate_info = Fictitious nsid in 
                         let error,blackboard,predicate_id = allocate parameter handler error blackboard predicate_info  in 
                         let error,log_info,blackboard = init_fictitious_action log_info error predicate_id  blackboard in
                         let error,log_info,blackboard = 
                           List.fold_left 
                             (fun (error,log_info,blackboard) list -> 
                               let blackboard = {blackboard with pre_nsteps = blackboard.pre_nsteps+1} in 
                               let log_info = CI.Po.K.P.inc_n_side_events log_info in 
                               let side_effect = 
                                 List.fold_left 
                                   (fun list (_,a,_) -> 
                                     match a 
                                     with 
                                       | None -> list
                                       | Some a -> a::list)
                                   []
                                   list 
                               in 
                               let side_effect = CI.Po.K.side_effect_of_list 
                                 side_effect in 
                               let _ = A.set blackboard.pre_side_effect_of_event 
                                 blackboard.pre_nsteps
                                 side_effect in
                               let error,blackboard = 
                                 List.fold_left
                                   (fun (error,blackboard) (predicate_id,_,(test,action)) -> 
                                     add_fictitious_action error test action predicate_id blackboard)
                                   (error,blackboard) 
                                   ((predicate_id,None,(Counter 0,Counter 1))::list)
                               in 
                               error,log_info,blackboard)
                             (error,log_info,blackboard)
                             potential_target
                         in 
                         error,
                         blackboard,
                         (predicate_id::fictitious_list),
                         (predicate_id::fictitious_local_list),
                         unambiguous_side_effects
                       end
                 end)
               (error,blackboard,fictitious_list,fictitious_local_list,[])
               side_effect 
           in 
           let error,blackboard,test_map = 
             List.fold_left 
               (fun (error,blackboard,map) test -> 
                 let error,blackboard,test_list = predicates_of_test parameter handler error blackboard test in
                 error,blackboard,build_map test_list map)
               (error,blackboard,PredicateidMap.empty)
               test_list in 
           let error,blackboard,action_map,test_map = 
             List.fold_left 
               (fun (error,blackboard,action_map,test_map) action -> 
                 let error,blackboard,action_list,test_list = predicates_of_action parameter handler error blackboard init action in 
                 error,blackboard,build_map action_list action_map,build_map test_list test_map)
               (error,blackboard,PredicateidMap.empty,test_map)
               action_list in 
           let g x = 
             match x 
             with 
               | None -> Unknown
               | Some x -> x
           in 
           let merged_map = 
             PredicateidMap.merge 
               (fun _ test action -> Some(g test,g action))
               test_map
               action_map 
           in 
           let merged_map = 
             List.fold_left 
               (fun map pid -> PredicateidMap.add pid (Counter 1,Undefined) map)
               merged_map
               fictitious_local_list 
           in 
           let merged_map = 
             List.fold_left 
               (fun map (pid,_,(test,action)) -> add_state pid (test,action) map)
               merged_map
               unambiguous_side_effects
           in 
           let side_effect = 
             List.fold_left 
               (fun list (_,a,_) -> 
                 match a 
                 with 
                   | None -> list
                   | Some a -> a::list)
               []
               unambiguous_side_effects 
           in 
           if side_effect = []
             && PredicateidMap.is_empty  merged_map 
           then 
             error,log_info,blackboard 
           else 
             begin 
               let nsid = blackboard.pre_nsteps + 1 in 
               let _ = A.set blackboard.pre_side_effect_of_event nsid (CI.Po.K.side_effect_of_list side_effect) in
               let _ = A.set pre_event nsid step in 
               let pre_steps_by_column = 
                 PredicateidMap.fold 
                   (fun id (test,action) map -> 
                     begin 
                       let value,list = A.get map id in 
                       let value' = value + 1 in 
                       let _ = fadd id action blackboard.history_of_predicate_values_to_predicate_id in 
                       let _ = A.set map id (value',(nsid,value,test,action)::list)
                   in map
                     end)
                   merged_map
                   blackboard.pre_steps_by_column 
               in 
               let _ = A.set blackboard.pre_kind_of_event nsid (type_of_step (CI.Po.K.type_of_refined_step step)) in 
               let observable_list = 
                 if CI.Po.K.is_obs_of_refined_step step 
                 then 
                   ([nsid],CI.Po.K.simulation_info_of_refined_step step)::blackboard.pre_observable_list 
                 else
                   blackboard.pre_observable_list 
               in 
               let blackboard = 
                 { 
                   blackboard with 
                     pre_event = pre_event ;
                     pre_fictitious_list = fictitious_list ; 
                     pre_steps_by_column = pre_steps_by_column; 
                     pre_nsteps = nsid;
                     pre_observable_list = observable_list; 
                 }
               in 
               error,log_info,blackboard 
             end 

         let finalize parameter handler error log_info blackboard = 
           let l = blackboard.pre_fictitious_list in 
           match l 
           with 
             | [] -> error,log_info,blackboard 
             | _ -> 
               let nsid = blackboard.pre_nsteps + 1 in 
               let log_info = CI.Po.K.P.inc_n_side_events log_info in 
               let observable_list = 
                 List.rev_map (fun (x,info) -> (nsid::x,info)) (List.rev blackboard.pre_observable_list) 
               in 
               let blackboard = 
                 {
                   blackboard 
                  with 
                    pre_nsteps = nsid ;
                    pre_observable_list = observable_list ;
                    pre_fictitious_observable = Some nsid ;
                 }
               in 
               let error,blackboard = 
                 List.fold_left
                   (fun (error,blackboard) predicate_id ->             
                     add_fictitious_action error Undefined Unknown predicate_id blackboard)
                   (error,blackboard)
                   l
               in 
               error,log_info,blackboard
                 
  (**interface*)
         let n_predicates parameter handler error blackboard = 
           error,blackboard.pre_ncolumn+1
             
         let event_list_of_predicate parameter handler error blackboard predicate_id = 
           try 
             error,snd (A.get blackboard.pre_steps_by_column predicate_id) 
           with 
             | _ -> 
               let error_list,error = CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "event_list_of_predicate") (Some "881") (Some "Unknown predicate id") (failwith "event_list_of_predicate") in 
               CI.Po.K.H.raise_error parameter handler error_list error []
                 
         let n_events_per_predicate parameter handler error blackboard predicate_id = 
           try 
             error,fst (A.get blackboard.pre_steps_by_column predicate_id) 
           with 
             | _ -> 
               let error_list,error = CI.Po.K.H.create_error parameter handler error (Some "blackboard_generation.ml") None (Some "n_events_per_predicate") (Some "889") (Some "Unknown predicate id") (failwith "n_events_per_predicate") in 
               CI.Po.K.H.raise_error parameter handler error_list error 0
                 
         let n_events parameter handler error blackboard = 
           error,blackboard.pre_nsteps+1 
             
         let mandatory_events parameter handler error blackboard = 
           error,blackboard.pre_observable_list 
             
         let get_fictitious_observable parameter handler error blackboard = 
           error,blackboard.pre_fictitious_observable
             
         let get_side_effect parameter handler error blackboard = 
           error,blackboard.pre_side_effect_of_event
             
          
          end:PreBlackboard)
           

      




