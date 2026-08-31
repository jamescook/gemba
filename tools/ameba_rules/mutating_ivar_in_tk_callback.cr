module Ameba::Rule::Lint
  # Disallows directly mutating an instance variable's Hash/Array/Set
  # from inside a Tk callback block - `App#bind`/`Widget#bind`/
  # `Interp#register_callback`, or any method configured via
  # `CallbackMethodNames`.
  #
  # Tk's own event dispatch can be RECURSIVE: destroying a window
  # synchronously destroys its children first, and each child's own
  # `<Destroy>` re-enters Crystal's callback dispatch before an
  # ancestor's own handler for the same event has returned (any event a
  # widget's own teardown can trigger is exposed to this, `<Destroy>`
  # is simply the case that is essentially guaranteed to happen in
  # practice). A block that mutates a shared ivar directly - `@foo.delete`,
  # `@foo << x`, `@foo[k] = v`, `@foo.clear`, ... - can run nested
  # inside an ENCLOSING invocation of the very same callback (or a
  # different one) that still holds a live reference into the same
  # collection, corrupting it. This is not hypothetical: a from-source
  # reproduction crashed inside `Hash#delete_impl` and, separately,
  # `Hash#[]?`, in two different Hashes in two different classes, both
  # reached through exactly this recursive dispatch chain - see
  # Tryst.defer_unless_idle's own doc comment (interp.cr) for the full
  # writeup and the general fix this rule exists to keep anyone from
  # needing to rediscover by hand.
  #
  # ```
  # # Bad - mutates @entries directly inside the callback body:
  # app.bind(path, "<Destroy>") do |_args, _signal|
  #   @entries.delete(path)
  # end
  #
  # # Good - routes the mutation through something that can defer it:
  # app.bind(path, "<Destroy>") do |_args, _signal|
  #   Tryst.defer_unless_idle { @entries.delete(path) }
  # end
  # ```
  #
  # A mutation reached only through a plain method call (not written
  # inline in the block) is NOT flagged - this rule catches the
  # mistake at the point it is actually made, not every possible path
  # to it; the method itself is the place to apply
  # `Tryst.defer_unless_idle` (or an equivalent guard) once.
  #
  # YAML configuration example:
  #
  # ```
  # Lint/MutatingIvarInTkCallback:
  #   Enabled: true
  #   CallbackMethodNames:
  #     - bind
  #     - register_callback
  #   MutatingMethodNames:
  #     - delete
  #     - delete_if
  #     - clear
  #     - push
  #     - <<
  #     - shift
  #     - pop
  #     - reject!
  #     - select!
  #     - merge!
  #     - "[]="
  #     - concat
  #     - unshift
  #     - compact!
  #     - uniq!
  #     - sort!
  #     - sort_by!
  #     - shuffle!
  #     - flatten!
  # ```
  class MutatingIvarInTkCallback < Base
    properties do
      since_version "0.1.0"
      description "Disallows mutating an ivar directly inside a Tk callback block - Tk's own event dispatch can re-enter the block while an enclosing invocation still holds a live reference into the same collection"
      callback_method_names %w[bind register_callback]
      mutating_method_names %w[
        delete delete_if clear push << shift pop reject! select! merge!
        []= concat unshift compact! uniq! sort! sort_by! shuffle! flatten!
      ]
      # A mutation inside one of these methods' own block is exactly the
      # sanctioned fix (see Tryst.defer_unless_idle) - the visitor stops
      # there rather than flagging what it correctly defers.
      safe_wrapper_method_names %w[defer_unless_idle]
    end

    MSG = "Mutating `%s.%s` directly inside a `%s` callback block - Tk's own event dispatch can re-enter this block (e.g. a recursive <Destroy> cascade) while an enclosing invocation still holds a live reference into the same collection, corrupting it. Route the mutation through a method that can defer it (see Tryst.defer_unless_idle) instead of mutating inline here."

    def test(source, node : Crystal::Call)
      return unless node.name.in?(callback_method_names)
      return unless block = node.block

      block.body.accept(MutationVisitor.new(self, source, node.name))
    end

    private class MutationVisitor < Crystal::Visitor
      def initialize(@rule : MutatingIvarInTkCallback, @source : Source, @callback_name : String)
      end

      def visit(node : Crystal::Call) : Bool
        return false if node.name.in?(@rule.safe_wrapper_method_names)

        if (obj = node.obj).is_a?(Crystal::InstanceVar) && node.name.in?(@rule.mutating_method_names)
          @source.add_issue(@rule, node, MSG % {obj, node.name, @callback_name})
        end
        true
      end

      def visit(node : Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
