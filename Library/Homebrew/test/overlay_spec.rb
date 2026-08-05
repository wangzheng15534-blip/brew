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
      overlay_active?:     true,
      overlay_base_prefix: base_prefix.to_s,
    )
    allow(described_class).to receive(:sync!)
    allow(described_class).to receive(:verify_base_generation!)
    Formula.clear_cache
    Keg.clear_cache
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

    expect(described_class.install_rack("foo")).to eq(transaction.staging_rack)
    expect(transaction.staging_rack).to be_a_directory
    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").realpath).to eq(base_keg.parent)
    expect(transaction.transaction_dir/"state").to have_file_content("staging\n")
    expect(transaction.transaction_dir/"base_generation").to have_file_content("#{base_generation}\n")
  ensure
    transaction&.rollback!
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
end
