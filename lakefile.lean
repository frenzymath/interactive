import Lake
open Lake DSL

require batteries from git "https://github.com/leanprover-community/batteries" @ "v4.16.0"
require Cli from git "https://github.com/leanprover/lean4-cli.git" @ "main"
require jixia from git "https://github.com/frenzymath/jixia" @ "main"
require metalib from git "https://github.com/frenzymath/metalib" @ "main"

package interactive where
  leanOptions := #[
    ⟨`autoImplicit, false⟩,
    ⟨`relaxedAutoImplicit, false⟩
  ]

lean_lib Interactive where

@[default_target]
lean_exe interactive where
  root := `Main
  supportInterpreter := true
