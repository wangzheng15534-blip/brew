# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "unlink"
require "overlay"

module Homebrew
  module Cmd
    class UnlinkCmd < AbstractCommand
      cmd_args do
        description <<~EOS
          Remove symlinks for <formula> from Homebrew's prefix. This can be useful
          for temporarily disabling a formula:
          `brew unlink` <formula> `&&` <commands> `&& brew link` <formula>
        EOS
        switch "-n", "--dry-run",
               description: "List files which would be unlinked without actually unlinking or " \
                            "deleting any files."

        named_args :installed_formula, min: 1
      end

      sig { override.void }
      def run
        options = { dry_run: args.dry_run?, verbose: args.verbose? }
        kegs = args.named.to_default_kegs
        if (keg = kegs.find { |candidate| Homebrew::Overlay.base_formula_available?(candidate.name) })
          odie <<~EOS
            `brew unlink #{keg.name}` is unsupported while #{keg.name} has an administrator-base fallback.
            Unlinking the user realization would immediately expose the base executable through PATH.
            Uninstall the user realization to fall back intentionally, or ask an administrator to change the base.
          EOS
        end

        kegs.each do |keg|
          if args.dry_run?
            puts "Would remove:"
            keg.unlink(**options)
            next
          end

          Unlink.unlink(keg, dry_run: args.dry_run?, verbose: args.verbose?)
        end
      end
    end
  end
end
