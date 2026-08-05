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

  before do
    user_cellar.mkpath
    base_cellar.mkpath

    stub_const("HOMEBREW_PREFIX", prefix)
    stub_const("HOMEBREW_CELLAR", user_cellar)
    allow(Homebrew::EnvConfig).to receive_messages(
      overlay_active?:      true,
      overlay_base_prefix:  base_prefix.to_s,
    )
    allow(described_class).to receive(:sync!)
    Formula.clear_cache
    Keg.clear_cache
  end

  def add_base_formula(name, version)
    keg = base_cellar/name/version
    (keg/"bin").mkpath
    (keg/"bin"/name).write("base\n")
    FileUtils.ln_s(base_cellar/name, user_cellar/name)
    keg
  end

  it "recognizes and prepares an inherited rack for a local installation" do
    base_keg = add_base_formula("foo", "1.0")

    expect(described_class.inherited_rack?(user_cellar/"foo")).to be(true)
    expect(described_class.inherited_keg?(user_cellar/"foo/1.0")).to be(true)
    expect(described_class.prepare_formula_install!("foo")).to be(true)
    expect(user_cellar/"foo").to be_a_directory
    expect(user_cellar/"foo").not_to be_a_symlink
    expect(base_keg).to exist
  end

  it "restores the base rack when the local rack becomes empty" do
    add_base_formula("foo", "1.0")
    described_class.prepare_formula_install!("foo")

    expect(described_class.restore_inherited_rack!("foo")).to be(true)
    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").readlink).to eq(base_cellar/"foo")
    expect(described_class).to have_received(:sync!)
  end

  it "discards a partial local rack when an inherited install rolls back" do
    add_base_formula("foo", "1.0")
    described_class.prepare_formula_install!("foo")
    (user_cellar/"foo/2.0/bin").mkpath
    (user_cellar/"foo/2.0/bin/foo").write("partial\n")

    expect(described_class.rollback_formula_install!("foo")).to be(true)
    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").readlink).to eq(base_cellar/"foo")
    expect(user_cellar/"foo/2.0").not_to exist
    expect(described_class).to have_received(:sync!)
  end

  it "does not replace a nonempty local rack" do
    add_base_formula("foo", "1.0")
    described_class.prepare_formula_install!("foo")
    (user_cellar/"foo/2.0").mkpath

    expect(described_class.restore_inherited_rack!("foo")).to be(false)
    expect(user_cellar/"foo/2.0").to be_a_directory
  end

  it "maps base-store kegs into the active prefix Cellar" do
    base_keg = add_base_formula("foo", "1.0")

    expect(described_class.logical_keg_path(base_keg.realpath)).to eq(user_cellar/"foo/1.0")
  end

  it "removes only links recorded by the overlay synchronizer" do
    target = "../Cellar/foo/1.0/bin/foo"
    link = prefix/"bin/foo"
    link.dirname.mkpath
    FileUtils.ln_s(target, link)

    state_file = prefix/"var/homebrew/overlay-links.tsv"
    state_file.dirname.mkpath
    state_file.write("#{link}\t#{target}\n")

    expect(described_class.remove_inherited_prefix_link!(link)).to be(true)
    expect(link).not_to be_a_symlink
  end

  it "keeps a user replacement whose target differs from the recorded base link" do
    replacement = root/"replacement"
    replacement.write("user\n")
    link = prefix/"bin/foo"
    link.dirname.mkpath
    FileUtils.ln_s(replacement, link)

    state_file = prefix/"var/homebrew/overlay-links.tsv"
    state_file.dirname.mkpath
    state_file.write("#{link}\t../Cellar/foo/1.0/bin/foo\n")

    expect(described_class.remove_inherited_prefix_link!(link)).to be(false)
    expect(link.readlink).to eq(replacement)
  end

  it "maps Keg.for through the active prefix but preserves a direct base path" do
    base_keg = add_base_formula("foo", "1.0")
    base_bin = base_prefix/"bin/foo"
    base_bin.dirname.mkpath
    FileUtils.ln_s(base_keg/"bin/foo", base_bin)
    user_bin = prefix/"bin/foo"
    user_bin.dirname.mkpath
    FileUtils.ln_s("../Cellar/foo/1.0/bin/foo", user_bin)

    expect(Pathname(Keg.for(user_bin).to_path)).to eq(user_cellar/"foo/1.0")
    expect(Pathname(Keg.for(base_bin).to_path)).to eq(base_keg)
    expect(Pathname(Keg.new(base_keg).to_path)).to eq(base_keg)
  end
end
