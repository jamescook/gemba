# Custom ameba binary for this project - mirrors lib/ameba/bin/ameba.cr's
# own documented extension pattern ("Require ameba extensions here which
# are added as project dependencies") but requires a LOCAL custom rule
# instead of an external shard, since this rule only makes sense for a
# Tryst-based project's own callback idiom.
#
# Build with (from the repo root, after `shards install` has populated
# lib/ameba):
#   crystal build tools/ameba_rules/ameba.cr -o lib/ameba/bin/ameba
#
# Overwrites the stock lib/ameba/bin/ameba the plain `make` build in
# lib/ameba would produce - deliberate: .githooks/pre-commit invokes
# that exact path, so building this custom binary there is what wires
# MutatingIvarInTkCallback into the pre-commit gate with no hook changes.
require "ameba/cli"
require "./mutating_ivar_in_tk_callback"
