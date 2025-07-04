import Lean
import Metalib.Parse
import Analyzer.Goal
import Interactive.JsonRpc
import Interactive.Unify

open Lean Core Meta Elab Command Tactic

namespace Interactive.Handler
open JsonRpc

structure ProofVariable where
  name : Name
  type : String
deriving FromJson

structure ProofGoal where
  context : Array ProofVariable
  type : String
deriving FromJson

class MonadHandler (m : Type _ → Type _) [Monad m] [MonadExceptOf Error m] where
  /-- returns a new state id.
  this method can be async or lazy, i.e., the new state might not be ready yet -/
  runTactic : (sid : Nat) → (tactic : String) → (heartbeats : Nat) → m Nat

  /-- returns pretty-printed main goal and number of goals of the given state id -/
  getState : (sid : Nat) → m (Array Analyzer.Goal)

  getMessages : (sid : Nat) → m (Array SerialMessage)

  /-- returns a list of possible interpretations along with field names -/
  resolveName : (sid : Nat) → (name : String) → m (List (Name × List String))

  /-- tries to unify two terms, returning a solution if possible -/
  unify : (sid : Nat) → (s1 s2 : String) → m (Option (Array (Name × Option String)))

  /-- creates a new state from user input -/
  newState : (state : List ProofGoal) → m Nat

  getPosition : m (Option Position)

  /-- admit all goals -/
  giveUp : (sid : Nat) → m Nat

  /-- ends the tactic execution -/
  commit : (sid : Nat) → m Unit

register_handler MonadHandler handleRequest

variable {m : Type _ → Type _} [Monad m] [MonadExceptOf Error m] [MonadHandler m] (req : Request)

protected def handleLine [MonadLift IO m]: m Unit := do
  let line ← (← IO.getStdin).getLine
  let response ← match Json.parse line with
  | .ok json =>
    match (fromJson? json : Except String Request) with
    | .ok req =>
      try
        handleRequest req
      catch e =>
        pure <| Response.mkError req.id e
    | .error e =>
      pure ⟨ none, none, some <| invalidRequest e ⟩
  | .error e =>
    pure ⟨ none, none, some <| parseError e ⟩
  IO.println (toJson response).compress
  (← IO.getStdout).flush


structure Node where
  tacticState : Tactic.SavedState
  parent : Nat
  tactic : String

structure State where
  nodes : Array Node
  running : Bool

variable {m : Type _ → Type _} [Monad m] [MonadState State m]

private def push (n : Node) : m Unit :=
  modify fun s => { s with nodes := s.nodes.push n }

private def gets [MonadExceptOf Error m] (sid : Nat) : m Node := do
  match (← get).nodes[sid]? with
  | .some n => return n
  | .none => throw <| invalidParams "sid out of range"

abbrev HandlerM := StateT State (ExceptT Error TacticM)

instance : MonadLift IO HandlerM where
  monadLift := liftM

open MonadExceptOf -- for throw

def initialState : TacticM State := do
  pruneSolvedGoals
  let s ← Tactic.saveState
  return {
    nodes := Array.mkArray1 ⟨ s, 0, "" ⟩,
    running := true,
  }

def runHandlerM {α : Type _} (handler : HandlerM α) (s : State) : TacticM α := do
  match ← (handler.run' s).run with
  | .ok r => return r
  | .error e => throwNestedTacticEx `Interactive <| .error (← getRef) (.ofFormat (.text e.message))

def saveAsNewNode (parent : Nat) (tactic : String) : HandlerM Nat := do
  pruneSolvedGoals
  let i := (← get).nodes.size
  push {
    tacticState := ← Tactic.saveState,
    parent,
    tactic,
  }
  return i

def withHeartbeats {α : Type _} [Monad m] [MonadWithReaderOf Core.Context m] (heartbeats : Nat) : m α → m α :=
  withReader (fun s => { s with maxHeartbeats := heartbeats })

instance : MonadHandler HandlerM where
  runTactic sid tactic heartbeats := do
    let ts := (← gets sid).tacticState
    ts.restore
    match Parser.runParserCategory (← getEnv) `tactic tactic with
    | .error e => throw <| Error.mk 0 "Lean parser error" e
    | .ok stx =>

      let handler (e : Exception) : TacticM (Except Error Unit) := do
        ts.restore
        return .error <| .mk 1 "Tactic error" (← e.toMessageData.toString)
      ExceptT.mk <| tryCatchRuntimeEx (handler := handler) <|
        MonadExcept.tryCatch (do
          withHeartbeats heartbeats <| evalTactic stx
          return .ok ()
        ) handler

      let s ← getThe Core.State
      if s.messages.hasErrors then
        let ms ← liftM $ s.messages.toList.mapM Message.toString
        throw <| Error.mk 1 "Tactic error" <| some <| toJson ms
    saveAsNewNode sid tactic

  getState sid := do
    (← gets sid).tacticState.restore
    let goals ← getGoals
    goals.toArray.mapM fun goal => Analyzer.Goal.fromMVar goal

  getMessages sid := do
    (← gets sid).tacticState.restore
    let messages ← getMessageLog
    messages.toArray.mapM fun m => m.serialize

  resolveName sid name := do
    (← gets sid).tacticState.restore
    return (← resolveGlobalName (.mkSimple name))

  unify sid s₁ s₂ := do
    (← gets sid).tacticState.restore
    let (stx₁, stx₂) ← try
      pure (← parseTerm s₁, ← parseTerm s₂)
    catch e =>
      throw <| Error.mk 2 "Parse error" (← e.toMessageData.toString)
    try
      unify stx₁ stx₂
    catch e =>
      throw <| Error.mk 3 "Elaboration error" (← e.toMessageData.toString)

  newState goals := withLCtx .empty #[] do
    let gs ← goals.mapM fun g => parseGoal (g.context.map fun v => (v.name, v.type)) .anonymous g.type
    setGoals gs
    saveAsNewNode 0 ""

  getPosition := do
    let pos := (← getRef).getPos?
    let fileMap ← getFileMap
    return pos.map fileMap.toPosition

  giveUp sid := do
    (← gets sid).tacticState.restore
    for goal in ← getGoals do
      goal.admit
    saveAsNewNode sid ""

  commit sid := do
    (← gets sid).tacticState.restore
    modify fun s => { s with running := false }

protected def loop : HandlerM Unit := do
  while (← get).running do
    Handler.handleLine

end Interactive.Handler
