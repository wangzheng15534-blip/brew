# typed: strict
# frozen_string_literal: true

require "env_config"
require "fileutils"

module Homebrew
  # Helpers for the optional non-service package overlay. The active prefix is
  # an ordinary Homebrew layout whose Cellar contains real user racks and
  # symlinked administrator racks. All mutations remain in the active prefix.
  module Overlay
    extend T::Sig

    @link_state_entries = T.let(nil, T.nilable(T::Hash[String, String]))

    class InheritedKegError < RuntimeError
      extend T::Sig

      sig { params(keg_path: Pathname, base_prefix: Pathname).void }
      def initialize(keg_path, base_prefix)
        super <<~EOS
          #{keg_path} is inherited from #{base_prefix} and cannot be removed from the user overlay.
          Reinstall or upgrade the formula to create a writable copy in #{HOMEBREW_PREFIX}.
          Ask an administrator to change the base package itself.
        EOS
      end
    end

    sig { returns(T::Boolean) }
    def self.active?
      Homebrew::EnvConfig.overlay_active?
    end

    sig { returns(Pathname) }
    def self.base_prefix
      value = Homebrew::EnvConfig.overlay_base_prefix
      if value.nil? || value.empty?
        raise "HOMEBREW_OVERLAY_BASE_PREFIX is required for an active overlay"
      end

      Pathname(value).expand_path
    end

    sig { returns(Pathname) }
    def self.base_cellar
      base_prefix/"Cellar"
    end

    sig { params(path: Pathname).returns(Pathname) }
    def self.canonical_path(path)
      path.realpath
    rescue Errno::ENOENT, Errno::EACCES
      path.expand_path
    end

    sig { params(path: Pathname, root: Pathname).returns(T::Boolean) }
    def self.path_under?(path, root)
      path = path.expand_path
      root = root.expand_path
      path == root || path.to_s.start_with?("#{root}/")
    end

    sig { params(path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_path?(path)
      return false unless active? && base_cellar.directory?

      path_under?(canonical_path(Pathname(path)), canonical_path(base_cellar))
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.valid_keg_path?(path)
      cellar = canonical_path(path.parent.parent)
      candidate_cellars = [HOMEBREW_CELLAR]
      candidate_cellars << base_cellar if active?

      candidate_cellars.any? do |candidate|
        candidate.directory? && canonical_path(candidate) == cellar
      end
    end

    sig { params(rack: Pathname).returns(T::Boolean) }
    def self.inherited_rack?(rack)
      active? && rack.symlink? && inherited_path?(rack)
    end

    sig { params(keg_path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_keg?(keg_path)
      active? && inherited_path?(keg_path)
    end

    # Map a real base keg path back into the active prefix's logical Cellar.
    # Keg.for uses this only when the path was reached through the user prefix.
    sig { params(real_keg_path: Pathname).returns(Pathname) }
    def self.logical_keg_path(real_keg_path)
      return real_keg_path unless active?

      real_keg_path = canonical_path(real_keg_path)
      return real_keg_path unless real_keg_path.parent.parent == canonical_path(base_cellar)

      HOMEBREW_CELLAR/real_keg_path.parent.basename/real_keg_path.basename
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.active_prefix_path?(path)
      active? && path_under?(path.expand_path, HOMEBREW_PREFIX.expand_path)
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.prepare_formula_install!(formula_name)
      return false unless active?

      rack = HOMEBREW_CELLAR/formula_name
      return false unless inherited_rack?(rack)

      rack.unlink
      rack.mkpath
      clear_caches!
      sync!
      true
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.restore_inherited_rack!(formula_name)
      return false unless active?

      rack = HOMEBREW_CELLAR/formula_name
      if rack.directory? && !rack.symlink? && rack.children.empty?
        rack.rmdir
      end
      return false if rack.exist? || rack.symlink?

      base_rack = base_cellar/formula_name
      return false unless base_rack.directory?

      rack.parent.mkpath
      File.symlink(base_rack, rack)
      clear_caches!
      sync!
      true
    end

    # Restore a rack that was inherited before a failed local install. The
    # caller may use this only after prepare_formula_install! returned true, so
    # the real rack was created empty by this process and can be discarded as
    # one transaction under the formula lock.
    sig { params(formula_name: String).returns(T::Boolean) }
    def self.rollback_formula_install!(formula_name)
      return false unless active?

      rack = HOMEBREW_CELLAR/formula_name
      base_rack = base_cellar/formula_name
      return false unless base_rack.directory?

      FileUtils.rm_rf(rack) if rack.exist? || rack.symlink?
      rack.parent.mkpath
      File.symlink(base_rack, rack)
      clear_caches!
      sync!
      true
    end

    sig { returns(Pathname) }
    def self.link_state_file
      HOMEBREW_PREFIX/"var/homebrew/overlay-links.tsv"
    end

    sig { returns(T::Hash[String, String]) }
    def self.link_state_entries
      @link_state_entries ||= T.let(
        if link_state_file.readable?
          link_state_file.each_line.filter_map do |line|
            path, target = line.chomp.split("\t", 2)
            next if path.nil? || path.empty? || target.nil? || target.empty?

            [path, target]
          end.to_h
        else
          {}
        end,
        T::Hash[String, String],
      )
    end
    private_class_method :link_state_entries

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.inherited_prefix_link?(path)
      return false unless active? && path.symlink?

      expected_target = link_state_entries[path.to_s]
      !expected_target.nil? && path.readlink.to_s == expected_target
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.remove_inherited_prefix_link!(path)
      return false unless inherited_prefix_link?(path)

      path.unlink
      true
    end

    sig { void }
    def self.sync!
      return unless active?

      script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
      Homebrew.safe_system "/bin/bash", script, "--sync"
      @link_state_entries = nil
    end

    sig { void }
    def self.clear_caches!
      T.unsafe(::Formula).clear_cache if defined?(::Formula)
      T.unsafe(::Keg).clear_cache if defined?(::Keg)
    end
    private_class_method :clear_caches!
  end
end
