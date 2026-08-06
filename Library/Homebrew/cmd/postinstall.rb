# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula_installer"
require "overlay"

module Homebrew
  module Cmd
    class Postinstall < AbstractCommand
      cmd_args do
        description <<~EOS
          Rerun the post-install steps for <formula>.
        EOS

        named_args :installed_formula, min: 1
      end

      sig { override.void }
      def run
        formulae = args.named.to_resolved_formulae
        if (formula = formulae.find { |candidate| Homebrew::Overlay.inherited_keg?(candidate.prefix) })
          raise Homebrew::Overlay::InheritedKegError.new(
            formula.prefix,
            Homebrew::Overlay.base_prefix,
          )
        end

        formulae.each do |f|
          Homebrew::Overlay.begin_mutation!
          ohai "Postinstalling #{f}"
          f.install_etc_var
          post_install_steps_defined = f.post_install_steps_defined?
          post_install_defined = f.post_install_defined?

          if post_install_steps_defined || post_install_defined
            fi = FormulaInstaller.new(f, **{ debug: args.debug?, quiet: args.quiet?, verbose: args.verbose? }.compact)
            fi.post_install
          else
            opoo "#{f}: no `post_install` method was defined in the formula!"
          end
          Homebrew::Overlay.bump_generation!
        end
      end
    end
  end
end
