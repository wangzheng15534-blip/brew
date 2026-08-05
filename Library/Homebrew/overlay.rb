# typed: strict
# frozen_string_literal: true

require "env_config"

module Homebrew
  # Helpers for the optional non-service package overlay. The shell bootstrap
  # constructs the environment view; this module keeps package mutations inside
  # the active user's Cellar and protects inherited parent kegs.
  module Overlay
    extend T::Sig

    @link_manifest_entries = T.let(nil, T.nilable(T::Hash[String, String]))

    class InheritedKegError < RuntimeError
      extend T::Sig

      sig { params(keg_path: Pathname, source_prefix: T.nilable(Pathname)).void }
      def initialize(keg_path, source_prefix)
        source = source_prefix ? " from #{source_prefix}" : ""
        super <<~EOS
          #{keg_path} is inherited#{source} and cannot be removed from this overlay.
          Install or upgrade the formula to create a writable local realization, or change the overlay parents.
        EOS
      end
    end

    sig { returns(T::Boolean) }
    def self.active?
      Homebrew::EnvConfig.overlay_active?
    end

    sig { returns(Pathname) }
    def self.user_cellar
      value = Homebrew::EnvConfig.overlay_user_cellar
      if value.nil? || value.empty?
        raise "HOMEBREW_OVERLAY_USER_CELLAR is required for an active overlay"
      end

      Pathname(value).expand_path
    end

    sig { returns(T::Array[Pathname]) }
    def self.parent_prefixes
      value = Homebrew::EnvConfig.overlay_parent_prefixes
      return [] if value.nil? || value.empty?

      value.split(File::PATH_SEPARATOR).filter_map do |path|
        next if path.empty?

        Pathname(path).expand_path
      end
    end

    sig { returns(T::Array[Pathname]) }
    def self.parent_cellars
      parent_prefixes.map { |prefix| prefix/"Cellar" }
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

    sig { params(path: T.any(Pathname, String)).returns(T.nilable(Pathname)) }
    def self.source_prefix_for(path)
      return unless active?

      real_path = canonical_path(Pathname(path))
      parent_prefixes.find do |prefix|
        cellar = prefix/"Cellar"
        cellar.directory? && path_under?(real_path, canonical_path(cellar))
      end
    end

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.valid_keg_path?(path)
      cellar = canonical_path(path.parent.parent)
      candidate_cellars = [HOMEBREW_CELLAR]
      candidate_cellars.concat(parent_cellars) if active?

      candidate_cellars.any? do |candidate|
        candidate.directory? && canonical_path(candidate) == cellar
      end
    end

    sig { params(rack: Pathname).returns(T::Boolean) }
    def self.inherited_rack?(rack)
      active? && rack.symlink? && !source_prefix_for(rack).nil?
    end

    sig { params(keg_path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_keg?(keg_path)
      return false unless active?

      !source_prefix_for(Pathname(keg_path)).nil?
    end

    # Map a real user-store or parent-store keg path back into the active
    # environment's logical Cellar. `Keg.for` uses this only when the original
    # path was reached through the active environment.
    sig { params(real_keg_path: Pathname).returns(Pathname) }
    def self.logical_keg_path(real_keg_path)
      return real_keg_path unless active?

      real_keg_path = canonical_path(real_keg_path)
      cellars = [HOMEBREW_CELLAR, *parent_cellars].select(&:directory?).map { |cellar| canonical_path(cellar) }
      return real_keg_path unless cellars.include?(real_keg_path.parent.parent)

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
      true
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.restore_inherited_rack!(formula_name)
      return false unless active?

      rack = user_cellar/formula_name
      if rack.directory? && !rack.symlink? && rack.children.empty?
        rack.rmdir
      end
      return false if rack.exist? || rack.symlink?

      parent_rack = parent_cellars.map { |cellar| cellar/formula_name }.find(&:directory?)
      return false unless parent_rack

      rack.parent.mkpath
      File.symlink(parent_rack, rack)
      clear_caches!
      sync!
      true
    end

    sig { returns(Pathname) }
    def self.link_manifest
      HOMEBREW_PREFIX/"var/homebrew/overlay-links.tsv"
    end

    sig { returns(T::Hash[String, String]) }
    def self.link_manifest_entries
      @link_manifest_entries ||= T.let(
        if link_manifest.readable?
          link_manifest.each_line.filter_map do |line|
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
    private_class_method :link_manifest_entries

    sig { params(path: Pathname).returns(T::Boolean) }
    def self.inherited_prefix_link?(path)
      return false unless active? && path.symlink?

      expected_target = link_manifest_entries[path.to_s]
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
      @link_manifest_entries = nil
    end

    sig { void }
    def self.clear_caches!
      T.unsafe(::Formula).clear_cache if defined?(::Formula)
      T.unsafe(::Keg).clear_cache if defined?(::Keg)
    end
    private_class_method :clear_caches!
  end
end
