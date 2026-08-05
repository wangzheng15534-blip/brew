# typed: strict
# frozen_string_literal: true

require "env_config"
require "fileutils"
require "fiddle"
require "rbconfig"
require "securerandom"

module Homebrew
  # Helpers for the optional non-service package overlay. The active prefix is
  # an ordinary Homebrew layout. Untouched administrator racks are inherited
  # as symlinks; a locally overridden formula uses a real native Cellar rack
  # containing the local keg and read-only links to other base versions.
  module Overlay
    extend T::Sig

    @link_state_entries = T.let(nil, T.nilable(T::Hash[String, String]))
    @install_transactions = T.let({}, T::Hash[String, T.untyped])

    class InheritedKegError < RuntimeError
      extend T::Sig

      sig { params(keg_path: Pathname, base_prefix: Pathname).void }
      def initialize(keg_path, base_prefix)
        super <<~EOS
          #{keg_path} is inherited from #{base_prefix} and cannot be modified from the user prefix.
          Reinstall or upgrade the formula to create a writable copy in #{HOMEBREW_PREFIX}.
          Ask an administrator to change the base package itself.
        EOS
      end
    end

    class TransactionFailure < RuntimeError; end

    TRANSACTION_MARKER = ".brew-overlay-transaction"
    AT_FDCWD = -100
    RENAME_EXCHANGE = 2
    RENAMEAT2_SYSCALLS = T.let(
      {
        "x86_64"  => 316,
        "aarch64" => 276,
        "arm64"   => 276,
        "ppc64le" => 357,
        "s390x"   => 347,
        "riscv64" => 276,
      }.freeze,
      T::Hash[String, Integer],
    )

    # A durable installation transaction for replacing an inherited formula.
    # Build and pour operations use a staging rack. Publication prepares a
    # complete native rack and uses Linux renameat2(RENAME_EXCHANGE) to swap it
    # with the inherited rack in one filesystem operation.
    class FormulaTransaction
      extend T::Sig

      sig { returns(String) }
      attr_reader :formula_name

      sig { returns(String) }
      attr_reader :version

      sig { returns(String) }
      attr_reader :id

      sig { returns(Pathname) }
      attr_reader :transaction_dir

      sig { returns(Pathname) }
      attr_reader :staging_rack

      sig { returns(Pathname) }
      attr_reader :staging_version

      sig { returns(Pathname) }
      attr_reader :replacement_rack

      sig { returns(Pathname) }
      attr_reader :final_rack

      sig { returns(Pathname) }
      attr_reader :final_version

      sig { params(formula: T.untyped).void }
      def initialize(formula)
        @formula_name = T.let(formula.name, String)
        @version = T.let(formula.pkg_version.to_s, String)
        raise ArgumentError, "invalid formula name: #{@formula_name}" unless Overlay.valid_formula_name?(@formula_name)
        raise ArgumentError, "invalid formula version: #{@version}" unless Overlay.valid_version_name?(@version)

        @id = T.let("#{Process.pid}-#{SecureRandom.hex(12)}", String)
        @transaction_dir = T.let(Overlay.transactions_dir/@id, Pathname)
        @staging_root = T.let(HOMEBREW_CELLAR/".homebrew-overlay-staging"/@id, Pathname)
        @staging_rack = T.let(@staging_root/@formula_name, Pathname)
        @staging_version = T.let(@staging_rack/@version, Pathname)
        @replacement_root = T.let(HOMEBREW_CELLAR/".homebrew-overlay-racks"/@id, Pathname)
        @replacement_rack = T.let(@replacement_root/@formula_name, Pathname)
        @final_rack = T.let(HOMEBREW_CELLAR/@formula_name, Pathname)
        @final_version = T.let(@final_rack/@version, Pathname)
        @published = T.let(false, T::Boolean)
        @finished = T.let(false, T::Boolean)
      end

      sig { returns(FormulaTransaction) }
      def start!
        raise "overlay transaction already exists: #{transaction_dir}" if transaction_dir.exist?

        Overlay.ensure_inherited_rack!(formula_name)
        transaction_dir.mkpath
        transaction_dir.chmod 0700
        staging_rack.mkpath
        staging_rack.chmod 0700
        write_metadata("formula", formula_name)
        write_metadata("version", version)
        write_state("staging")
        Overlay.register_transaction(self)
        self
      rescue Exception # rubocop:disable Lint/RescueException
        Overlay.unregister_transaction(formula_name, self)
        cleanup_paths!
        raise
      end

      sig { void }
      def publish!
        return if @published
        unless staging_version.directory? && !staging_version.symlink? && staging_version.children.any?
          raise TransactionFailure, "staged formula version is missing or empty: #{staging_version}"
        end

        relocate_staging_prefix!
        prepare_replacement_rack!
        write_state("publishing")
        Overlay.atomic_exchange!(final_rack, replacement_rack)
        write_state("published")
        @published = true
        Overlay.unregister_transaction(formula_name, self)
        Overlay.clear_caches!
      rescue Exception # rubocop:disable Lint/RescueException
        rollback!
        raise
      end

      sig { void }
      def commit!
        return if @finished
        raise TransactionFailure, "overlay transaction was not published" unless transaction_owns_final?

        write_state("committing")
        marker = final_version/TRANSACTION_MARKER
        marker.unlink
        write_state("committed")
        @finished = true
        Overlay.clear_caches!
        Overlay.sync!
        cleanup_paths!
      end

      sig { void }
      def rollback!
        return if @finished
        Overlay.unregister_transaction(formula_name, self)
        write_state("rolling-back") if transaction_dir.directory?

        if transaction_owns_final?
          Overlay.remove_links_to!(final_version)
          Overlay.atomic_exchange!(final_rack, replacement_rack)
        elsif !transaction_owns_replacement? && @published
          raise TransactionFailure, "refusing to roll back an unowned formula rack: #{final_rack}"
        end

        Overlay.clear_caches!
        Overlay.sync!
        cleanup_paths!
        @finished = true
      end

      private

      sig { params(path: Pathname).returns(T::Boolean) }
      def marker_owned?(path)
        marker = path/TRANSACTION_MARKER
        marker.file? && !marker.symlink? && marker.read.chomp == id
      end

      sig { returns(T::Boolean) }
      def transaction_owns_final?
        final_version.directory? && !final_version.symlink? && marker_owned?(final_version)
      end

      sig { returns(T::Boolean) }
      def transaction_owns_replacement?
        candidate = replacement_rack/version
        candidate.directory? && !candidate.symlink? && marker_owned?(candidate)
      end

      sig { params(name: String, value: String).void }
      def write_metadata(name, value)
        path = transaction_dir/name
        path.atomic_write("#{value}\n")
        path.chmod 0600
      end

      sig { params(value: String).void }
      def write_state(value)
        write_metadata("state", value)
      end

      sig { void }
      def prepare_replacement_rack!
        raise TransactionFailure, "overlay replacement rack already exists: #{replacement_rack}" if replacement_rack.exist?

        replacement_rack.mkpath
        replacement_rack.chmod 0700
        base_rack = Overlay.base_cellar/formula_name
        base_rack.children.each do |base_version|
          next unless base_version.directory? && !base_version.symlink?
          next if base_version.basename.to_s == version

          File.symlink(base_version, replacement_rack/base_version.basename)
        end

        File.rename(staging_version, replacement_rack/version)
        marker = replacement_rack/version/TRANSACTION_MARKER
        marker.atomic_write("#{id}\n")
        marker.chmod 0600
      end

      # Formulae built from source may embed Formula#prefix. During an overlay
      # transaction that is the staging path, not the path that will be
      # published. Relocate those references before the atomic rack exchange so
      # the resulting keg is indistinguishable from one built in the native
      # Cellar path.
      sig { void }
      def relocate_staging_prefix!
        old_prefix = staging_version.to_s
        new_prefix = final_version.to_s
        if new_prefix.bytesize > old_prefix.bytesize
          raise TransactionFailure, "overlay staging prefix is shorter than its final prefix"
        end

        require "keg"
        keg = Keg.new(staging_version)
        relocation = Keg::Relocation.new
        relocation.add_replacement_pair(:prefix, old_prefix, new_prefix)
        relocation.freeze
        keg.relocate_dynamic_linkage(relocation)
        keg.replace_text_in_files(relocation)

        # Preserve hardlinks while replacing any remaining text or script
        # occurrence omitted by Homebrew's normal text-file classifier.
        remaining = T.let([], T::Array[Pathname])
        keg.each_unique_file_matching(old_prefix) { |file| remaining << file }
        remaining.each do |file|
          if keg.binary_file?(file) && !file.text_executable?
            raise TransactionFailure, "unrelocated staging path remains in binary: #{file}"
          end

          contents = File.binread(file)
          next unless contents.include?(old_prefix)

          contents.gsub!(old_prefix, new_prefix)
          file.ensure_writable do
            File.open(file, "wb") { |io| io.write(contents) }
          end
        end

        staging_version.find do |path|
          next unless path.symlink?

          target = path.readlink
          next unless target.absolute?
          next unless target.to_s == old_prefix || target.to_s.start_with?("#{old_prefix}/")

          replacement = target.to_s.sub(/\A#{Regexp.escape(old_prefix)}/, new_prefix)
          path.unlink
          File.symlink(replacement, path)
        end

        unresolved = T.let([], T::Array[Pathname])
        keg.each_unique_file_matching(old_prefix) { |file| unresolved << file }
        unless unresolved.empty?
          raise TransactionFailure, "staging path remains after relocation: #{unresolved.first}"
        end
      end

      sig { void }
      def cleanup_paths!
        FileUtils.rm_rf(@staging_root) if @staging_root.exist?
        FileUtils.rm_rf(@replacement_root) if @replacement_root.exist? || @replacement_root.symlink?
        FileUtils.rm_rf(transaction_dir) if transaction_dir.exist?
        @staging_root.parent.rmdir_if_possible
        @replacement_root.parent.rmdir_if_possible
      end
    end

    private_constant :TRANSACTION_MARKER, :AT_FDCWD, :RENAME_EXCHANGE, :RENAMEAT2_SYSCALLS

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

    sig { returns(Pathname) }
    def self.transactions_dir
      HOMEBREW_PREFIX/"var/homebrew/overlay/transactions"
    end

    sig { params(name: String).returns(T::Boolean) }
    def self.valid_formula_name?(name)
      name.match?(/\A[A-Za-z0-9][A-Za-z0-9@+._-]*\z/)
    end

    sig { params(version: String).returns(T::Boolean) }
    def self.valid_version_name?(version)
      !version.empty? && version != "." && version != ".." && version.match?(/\A[^\/\0\r\n]+\z/)
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
      return true if @install_transactions.values.any? do |transaction|
        path.parent.expand_path == T.cast(transaction, FormulaTransaction).staging_rack.expand_path
      end

      cellar = canonical_path(path.parent.parent)
      candidate_cellars = [HOMEBREW_CELLAR]
      candidate_cellars << base_cellar if active?

      candidate_cellars.any? do |candidate|
        candidate.directory? && canonical_path(candidate) == cellar
      end
    end

    sig { params(rack: Pathname).returns(T::Boolean) }
    def self.inherited_rack?(rack)
      return false unless active? && rack.directory?
      return inherited_path?(rack) if rack.symlink?

      children = rack.children.reject { |child| child.basename.to_s.start_with?(".") }
      children.any? && children.all? { |child| inherited_keg?(child) }
    end

    sig { params(keg_path: T.any(Pathname, String)).returns(T::Boolean) }
    def self.inherited_keg?(keg_path)
      active? && inherited_path?(keg_path)
    end

    sig { params(formula_name: String).returns(T::Boolean) }
    def self.local_realizations?(formula_name)
      rack = HOMEBREW_CELLAR/formula_name
      return false unless rack.directory? && !rack.symlink?

      rack.children.any? do |child|
        !child.symlink? && child.directory? && !child.basename.to_s.start_with?(".")
      end
    end

    sig { params(formula: T.untyped).returns(T::Boolean) }
    def self.transaction_required?(formula)
      return false unless active? && valid_formula_name?(formula.name)

      base_rack = base_cellar/formula.name
      base_rack.directory? && !base_rack.symlink? && !local_realizations?(formula.name)
    end

    sig { params(formula: T.untyped).returns(T.nilable(FormulaTransaction)) }
    def self.begin_formula_transaction(formula)
      return unless transaction_required?(formula)

      FormulaTransaction.new(formula).start!
    end

    sig { params(transaction: FormulaTransaction).void }
    def self.register_transaction(transaction)
      existing = @install_transactions[transaction.formula_name]
      if existing && existing != transaction
        raise "another overlay install transaction is active for #{transaction.formula_name}"
      end
      @install_transactions[transaction.formula_name] = transaction
    end

    sig { params(formula_name: String, transaction: FormulaTransaction).void }
    def self.unregister_transaction(formula_name, transaction)
      @install_transactions.delete(formula_name) if @install_transactions[formula_name] == transaction
    end

    sig { params(formula_name: String).returns(T.nilable(Pathname)) }
    def self.install_rack(formula_name)
      transaction = @install_transactions[formula_name]
      transaction&.staging_rack
    end

    sig { params(formula_name: String).void }
    def self.ensure_inherited_rack!(formula_name)
      base_rack = base_cellar/formula_name
      unless base_rack.directory? && !base_rack.symlink?
        raise TransactionFailure, "administrator formula rack is unavailable: #{base_rack}"
      end

      rack = HOMEBREW_CELLAR/formula_name
      if !rack.exist? && !rack.symlink?
        File.symlink(base_rack, rack)
      elsif rack.symlink?
        unless inherited_path?(rack) && canonical_path(rack) == canonical_path(base_rack)
          raise TransactionFailure, "refusing to replace non-inherited formula rack: #{rack}"
        end
      elsif !rack.directory?
        raise TransactionFailure, "formula rack is not a directory: #{rack}"
      elsif local_realizations?(formula_name)
        raise TransactionFailure, "formula rack already contains a local realization: #{rack}"
      end
    end

    # Atomically exchange two paths on Linux. Both paths are required to live
    # in the active Cellar so the operation is same-filesystem and cannot be
    # redirected through an arbitrary user path.
    sig { params(left: Pathname, right: Pathname).void }
    def self.atomic_exchange!(left, right)
      cellar = HOMEBREW_CELLAR.expand_path
      [left, right].each do |path|
        unless path_under?(path.expand_path, cellar) && (path.exist? || path.symlink?)
          raise TransactionFailure, "unsafe overlay exchange path: #{path}"
        end
      end

      syscall_number = RENAMEAT2_SYSCALLS[RbConfig::CONFIG.fetch("host_cpu")]
      if syscall_number.nil?
        raise TransactionFailure, "atomic overlay publication is unsupported on this CPU architecture"
      end

      syscall = Fiddle::Function.new(
        Fiddle.dlopen(nil)["syscall"],
        [Fiddle::TYPE_LONG, Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP,
         Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
        Fiddle::TYPE_LONG,
      )
      result = syscall.call(syscall_number, AT_FDCWD, left.to_s, AT_FDCWD, right.to_s, RENAME_EXCHANGE)
      return if result.zero?

      error = Fiddle.last_error
      raise SystemCallError.new("atomic overlay rack exchange failed", error)
    end

    # Remove only symlinks in native Homebrew link roots that resolve into the
    # supplied transaction-owned keg. This is intentionally conservative: no
    # regular file or unrelated user symlink is touched.
    sig { params(version_path: Pathname).void }
    def self.remove_links_to!(version_path)
      return unless active?

      %w[bin sbin include lib share Frameworks opt var/homebrew/linked].each do |relative_root|
        root = HOMEBREW_PREFIX/relative_root
        next unless root.directory? && !root.symlink?

        root.find do |path|
          next unless path.symlink?

          resolved = canonical_path(path)
          path.unlink if path_under?(resolved, version_path)
        end
      end
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
    def self.restore_inherited_rack!(formula_name)
      return false unless active?
      return false if local_realizations?(formula_name)
      base_rack = base_cellar/formula_name
      return false unless base_rack.directory? && !base_rack.symlink?

      sync!
      true
    end

    sig { returns(Pathname) }
    def self.link_state_file
      HOMEBREW_PREFIX/"var/homebrew/overlay/view.state"
    end

    sig { returns(T::Hash[String, String]) }
    def self.link_state_entries
      @link_state_entries ||= T.let(
        if link_state_file.readable? && !link_state_file.symlink?
          fields = link_state_file.binread.split("\0", -1)
          fields.pop while fields.last == ""
          fields.each_slice(2).filter_map do |relative, target|
            next if relative.nil? || target.nil? || relative.empty? || target.empty?

            [relative, target]
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
      return false unless active? && path.symlink? && active_prefix_path?(path)

      relative = path.relative_path_from(HOMEBREW_PREFIX).to_s
      expected_target = link_state_entries[relative]
      !expected_target.nil? && path.readlink.to_s == expected_target
    rescue ArgumentError
      false
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
      @link_state_entries = nil
    end
  end
end
