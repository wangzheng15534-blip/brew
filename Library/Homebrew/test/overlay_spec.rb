# typed: strict
# frozen_string_literal: true

require "keg"
require "overlay"

RSpec.describe Homebrew::Overlay do
  let(:root) { mktmpdir }
  let(:prefix) { root/"home/.linuxbrew" }
  let(:user_cellar) { prefix/"Cellar" }
  let(:base_prefix) { root/"home/linuxbrew/.linuxbrew" }
  let(:base_cellar) { base_prefix/"Cellar" }
  let(:formula) { instance_double(Formula, name: "foo", pkg_version: PkgVersion.parse("2.0")) }
  let(:base_generation) { "a" * 64 }

  before do
    user_cellar.mkpath
    base_cellar.mkpath
    (prefix/"var/homebrew/overlay/transactions").mkpath

    stub_const("HOMEBREW_PREFIX", prefix)
    stub_const("HOMEBREW_CELLAR", user_cellar)
    allow(Homebrew::EnvConfig).to receive_messages(
      overlay?:            true,
      overlay_active?:     true,
      overlay_base_prefix: base_prefix.to_s,
    )
    allow(described_class).to receive(:sync!)
    allow(described_class).to receive(:verify_base_generation!)
    described_class.clear_caches!
    Formula.clear_cache
    Keg.clear_cache
  end

  after do
    described_class.send(:release_mutation_lock!) if described_class.mutation_active?
  end

  def add_base_formula(name, version)
    keg = base_cellar/name/version
    (keg/"bin").mkpath
    (keg/"bin"/name).write("base\n")
    rack = user_cellar/name
    FileUtils.ln_s(base_cellar/name, rack) unless rack.exist? || rack.symlink?
    keg
  end

  def stage(transaction)
    (transaction.staging_version/"bin").mkpath
    (transaction.staging_version/"bin/foo").write("prefix=#{transaction.staging_version}\n")
    (transaction.staging_version/AbstractTab::FILENAME).write("{}\n")
    FileUtils.ln_s(transaction.staging_version/"bin/foo", transaction.staging_version/"absolute-link")
  end

  it "recognizes a symlinked administrator rack and keg as inherited" do
    add_base_formula("foo", "1.0")

    expect(described_class.inherited_rack?(user_cellar/"foo")).to be(true)
    expect(described_class.inherited_keg?(user_cellar/"foo/1.0")).to be(true)
    expect(described_class.local_realizations?("foo")).to be(false)
  end

  it "builds an inherited replacement in a staging rack" do
    base_keg = add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))

    owner_lock = prefix/"var/homebrew/overlay/transactions/.locks/#{transaction.id}.lock"
    expect(owner_lock).to be_a_file
    expect(system("flock", "-xn", owner_lock.to_s, "-c", "true", out: File::NULL, err: File::NULL)).to be(false)
    expect(described_class.install_rack("foo")).to eq(transaction.staging_rack)
    expect(transaction.staging_rack).to be_a_directory
    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").realpath).to eq(base_keg.parent)
    pending_journal = transaction.transaction_dir.parent/".new-#{transaction.id}"
    expect(pending_journal).not_to exist
    expect(transaction.transaction_dir.stat.mode & 0777).to eq(0700)
    expect(transaction.transaction_dir.children.map { |path| path.basename.to_s }.sort).to eq(
      %w[base_generation formula state version],
    )
    transaction.transaction_dir.children.each do |path|
      expect(path).to be_a_file
      expect(path).not_to be_a_symlink
      expect(path.stat.mode & 0777).to eq(0600)
    end
    expect(transaction.transaction_dir/"state").to have_file_content("staging\n")
    expect(transaction.transaction_dir/"base_generation").to have_file_content("#{base_generation}\n")
  ensure
    transaction&.rollback!
  end

  it "rejects symlinked formula transaction control directories" do
    add_base_formula("foo", "1.0")
    outside = root/"outside-staging"
    outside.mkpath
    FileUtils.ln_s(outside, user_cellar/".homebrew-overlay-staging")

    expect do
      described_class.begin_formula_transaction(formula, base_generation:)
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay directory component/)
    expect(outside.children).to be_empty
  end

  it "rejects hard-linked transaction owner locks before cleanup" do
    add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    owner_lock = prefix/"var/homebrew/overlay/transactions/.locks/#{transaction.id}.lock"
    peer = root/"owner-lock-peer"
    FileUtils.ln(owner_lock, peer)

    expect do
      transaction.rollback!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay transaction owner lock/)
    expect(peer).to have_file_content("")
    expect(transaction.transaction_dir).to be_a_directory

    peer.unlink
    transaction.rollback!
    expect(transaction.finished?).to be(true)
  end

  it "atomically publishes a native version-union rack and commits it" do
    base_keg = add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    stage(transaction)

    transaction.publish!

    expect(described_class.install_rack("foo")).to be_nil
    expect(user_cellar/"foo").to be_a_directory
    expect(user_cellar/"foo").not_to be_a_symlink
    expect(user_cellar/"foo/2.0").to be_a_directory
    expect(user_cellar/"foo/1.0").to be_a_symlink
    expect((user_cellar/"foo/1.0").realpath).to eq(base_keg)
    expect(transaction.replacement_rack).to be_a_symlink
    expect(user_cellar/"foo/2.0/.brew-overlay-transaction").to exist
    expect(user_cellar/"foo/2.0/bin/foo").to have_file_content("prefix=#{user_cellar}/foo/2.0\n")
    expect((user_cellar/"foo/2.0/absolute-link").readlink.to_s).to eq((user_cellar/"foo/2.0/bin/foo").to_s)

    transaction.commit!

    expect(user_cellar/"foo/2.0/.brew-overlay-transaction").not_to exist
    expect(user_cellar/"foo/2.0/.brew-overlay-base-generation").to have_file_content("#{base_generation}\n")
    expect(transaction.transaction_dir).not_to exist
    expect(transaction.replacement_rack).not_to exist
    expect(described_class).to have_received(:sync!)
  end

  it "does not accept a hard-linked transaction marker" do
    add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    stage(transaction)
    transaction.publish!
    marker = transaction.final_version/".brew-overlay-transaction"
    peer = root/"transaction-marker-peer"
    FileUtils.ln(marker, peer)

    expect do
      transaction.commit!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /transaction was not published/)
    expect(peer).to have_file_content("#{transaction.id}\n")

    peer.unlink
    transaction.rollback!
    expect(transaction.finished?).to be(true)
  end

  it "atomically restores the original inherited rack on rollback" do
    base_keg = add_base_formula("foo", "2.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    stage(transaction)

    transaction.publish!
    expect(user_cellar/"foo").to be_a_directory
    expect(user_cellar/"foo/2.0").to be_a_directory

    transaction.rollback!

    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").realpath).to eq(base_keg.parent)
    expect((user_cellar/"foo/2.0").realpath).to eq(base_keg)
    expect(transaction.transaction_dir).not_to exist
  end

  it "discards staging without touching the inherited rack" do
    base_keg = add_base_formula("foo", "1.0")
    transaction = T.must(described_class.begin_formula_transaction(formula, base_generation:))
    stage(transaction)

    transaction.rollback!

    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo/1.0").realpath).to eq(base_keg)
    expect(transaction.staging_version).not_to exist
  end

  it "does not stage over an existing local realization" do
    add_base_formula("foo", "1.0")
    (user_cellar/"foo").unlink
    (user_cellar/"foo/1.5").mkpath

    expect(described_class.begin_formula_transaction(formula, base_generation:)).to be_nil
  end

  it "distinguishes real local kegs from inherited versions" do
    add_base_formula("foo", "1.0")

    expect(described_class.local_keg_realization?("foo", "1.0")).to be(false)
    (user_cellar/"foo").unlink
    (user_cellar/"foo/2.0").mkpath
    expect(described_class.local_keg_realization?("foo", "2.0")).to be(true)
  end

  it "rejects installing through an inherited version symlink in a local rack" do
    base_keg = add_base_formula("foo", "1.0")
    (user_cellar/"foo").unlink
    (user_cellar/"foo/2.0").mkpath
    FileUtils.ln_s(base_keg, user_cellar/"foo/1.0")

    expect do
      described_class.validate_local_install_target!("foo", "1.0")
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /Refusing to install through that symlink/)
  end

  it "discards only a newly created local keg and restores the inherited view" do
    base_keg = add_base_formula("foo", "1.0")
    (user_cellar/"foo").unlink
    local_keg = user_cellar/"foo/2.0"
    local_keg.mkpath
    (local_keg/"payload").write("local
")

    expect(described_class.discard_local_keg!("foo", "2.0")).to be(true)
    expect(local_keg).not_to exist
    expect(base_keg).to exist
    expect(described_class).to have_received(:sync!)
  end

  it "never discards an inherited keg" do
    base_keg = add_base_formula("foo", "1.0")

    expect(described_class.discard_local_keg!("foo", "1.0")).to be(false)
    expect(base_keg).to exist
  end

  it "records and detects administrator base-generation drift for local kegs" do
    local_keg = user_cellar/"foo/2.0"
    local_keg.mkpath
    allow(described_class).to receive(:current_base_generation).and_return(base_generation)

    described_class.record_base_generation!(local_keg, base_generation)
    expect(described_class.base_generation_drift).to be_empty

    allow(described_class).to receive(:current_base_generation).and_return("b" * 64)
    expect(described_class.base_generation_drift).to eq([local_keg])
  end

  it "rejects unsafe administrator base-generation markers" do
    local_keg = user_cellar/"foo/2.0"
    local_keg.mkpath
    FileUtils.ln_s(root/"outside", local_keg/Homebrew::Overlay::BASE_GENERATION_MARKER)

    expect do
      described_class.record_base_generation!(local_keg, base_generation)
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe administrator base-generation marker/)
  end

  it "maps base-store kegs into the active prefix Cellar" do
    base_keg = add_base_formula("foo", "1.0")

    expect(described_class.logical_keg_path(base_keg.realpath)).to eq(user_cellar/"foo/1.0")
  end

  it "reads only relative NUL-delimited managed link state" do
    target = (base_prefix/"opt/foo").to_s
    link = prefix/"opt/foo"
    link.dirname.mkpath
    FileUtils.ln_s(target, link)

    state_file = prefix/"var/homebrew/overlay/view.state"
    state_file.dirname.mkpath
    state_file.binwrite("opt/foo\0#{target}\0")

    expect(described_class.remove_inherited_prefix_link!(link)).to be(true)
    expect(link).not_to be_a_symlink
  end

  it "rejects malformed or non-base managed link state" do
    link = prefix/"opt/foo"
    link.dirname.mkpath
    FileUtils.ln_s(base_prefix/"opt/foo", link)
    state_file = prefix/"var/homebrew/overlay/view.state"
    state_file.dirname.mkpath
    state_file.binwrite("opt/foo\0#{root}/outside/foo\0")

    expect do
      described_class.remove_inherited_prefix_link!(link)
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /invalid overlay view state/)
    expect(link).to be_a_symlink

    described_class.clear_caches!
    target = (base_prefix/"opt/foo").to_s
    state_file.binwrite("opt/foo\0#{target}\0opt/foo\0#{target}\0")
    expect do
      described_class.remove_inherited_prefix_link!(link)
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /invalid overlay view state/)
    expect(link).to be_a_symlink
  end

  it "rejects symlinked intermediate mutation-state directories" do
    FileUtils.rm_rf(prefix/"var")
    outside = root/"outside"
    outside.mkpath
    FileUtils.ln_s(outside, prefix/"var")

    expect do
      described_class.begin_mutation!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay directory component/)
    expect(outside/"homebrew/locks/overlay-mutation.lock").not_to exist
  end

  it "rejects a hard-linked mutation lock without modifying its peer" do
    lock_path = prefix/"var/homebrew/locks/overlay-mutation.lock"
    lock_path.dirname.mkpath
    victim = root/"lock-victim"
    victim.write("unchanged\n")
    victim.chmod 0600
    FileUtils.ln(victim, lock_path)

    expect do
      described_class.begin_mutation!
    end.to raise_error(Homebrew::Overlay::TransactionFailure, /unsafe overlay mutation lock/)
    expect(victim.read).to eq("unchanged\n")
    expect(victim.stat.mode & 0777).to eq(0600)
  end

  it "marks the prefix dirty before advancing its generation" do
    script = HOMEBREW_LIBRARY_PATH/"utils/overlay.sh"
    owner_matcher = a_string_matching(/\A[0-9]+-[0-9]+-[0-9a-f]{32}\z/)
    expected_environment = hash_including("HOMEBREW_OVERLAY_MUTATION_OWNER" => owner_matcher)

    expect(Homebrew).to receive(:safe_system)
      .with(expected_environment, "/bin/bash", script, "--mark-generation-dirty", prefix.to_s)
      .ordered
    expect(Homebrew).to receive(:safe_system)
      .with(expected_environment, "/bin/bash", script, "--bump-generation", prefix.to_s)
      .ordered

    described_class.begin_mutation!
    expect(described_class.mutation_active?).to be(true)
    lock_path = prefix/"var/homebrew/locks/overlay-mutation.lock"
    expect(system("flock", "-xn", lock_path.to_s, "-c", "true", out: File::NULL, err: File::NULL)).to be(false)

    described_class.bump_generation!
    expect(described_class.mutation_active?).to be(false)
  end
end
