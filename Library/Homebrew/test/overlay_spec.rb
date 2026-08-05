# typed: strict
# frozen_string_literal: true

require "keg"
require "overlay"

RSpec.describe Homebrew::Overlay do
  let(:root) { mktmpdir }
  let(:prefix) { root/"environment" }
  let(:user_cellar) { root/"packages/default/Cellar" }
  let(:base_prefix) { root/"base" }
  let(:base_cellar) { base_prefix/"Cellar" }

  before do
    prefix.mkpath
    user_cellar.mkpath
    base_cellar.mkpath
    FileUtils.ln_s(user_cellar, prefix/"Cellar")

    stub_const("HOMEBREW_PREFIX", prefix)
    stub_const("HOMEBREW_CELLAR", prefix/"Cellar")
    allow(Homebrew::EnvConfig).to receive_messages(
      overlay_active?:          true,
      overlay_parent_prefixes:  base_prefix.to_s,
      overlay_user_cellar:      user_cellar.to_s,
    )
    allow(described_class).to receive(:sync!)
    Formula.clear_cache
    Keg.clear_cache
  end

  def add_parent_formula(name, version)
    keg = base_cellar/name/version
    (keg/"bin").mkpath
    (keg/"bin"/name).write("parent\n")
    FileUtils.ln_s(base_cellar/name, user_cellar/name)
    keg
  end

  it "recognizes and prepares an inherited rack for a local installation" do
    parent_keg = add_parent_formula("foo", "1.0")

    expect(described_class.inherited_rack?(HOMEBREW_CELLAR/"foo")).to be(true)
    expect(described_class.inherited_keg?(HOMEBREW_CELLAR/"foo/1.0")).to be(true)
    expect(described_class.prepare_formula_install!("foo")).to be(true)
    expect(user_cellar/"foo").to be_a_directory
    expect(user_cellar/"foo").not_to be_a_symlink
    expect(parent_keg).to exist
  end

  it "restores the highest-precedence parent rack when the local rack is empty" do
    add_parent_formula("foo", "1.0")
    described_class.prepare_formula_install!("foo")

    expect(described_class.restore_inherited_rack!("foo")).to be(true)
    expect(user_cellar/"foo").to be_a_symlink
    expect((user_cellar/"foo").readlink).to eq(base_cellar/"foo")
    expect(described_class).to have_received(:sync!)
  end

  it "does not replace a nonempty local rack" do
    add_parent_formula("foo", "1.0")
    described_class.prepare_formula_install!("foo")
    (user_cellar/"foo/2.0").mkpath

    expect(described_class.restore_inherited_rack!("foo")).to be(false)
    expect(user_cellar/"foo/2.0").to be_a_directory
  end

  it "maps parent-store kegs into the active logical Cellar" do
    parent_keg = add_parent_formula("foo", "1.0")

    expect(described_class.logical_keg_path(parent_keg.realpath)).to eq(HOMEBREW_CELLAR/"foo/1.0")
  end

  it "removes only links recorded by the overlay synchronizer" do
    target = base_prefix/"bin/foo"
    target.dirname.mkpath
    target.write("parent\n")
    link = prefix/"bin/foo"
    link.dirname.mkpath
    FileUtils.ln_s(target, link)

    manifest = prefix/"var/homebrew/overlay-links.tsv"
    manifest.dirname.mkpath
    manifest.write("#{link}\t#{target}\n")

    expect(described_class.remove_inherited_prefix_link!(link)).to be(true)
    expect(link).not_to be_a_symlink
  end

  it "keeps a user replacement whose target differs from the manifest" do
    inherited_target = base_prefix/"bin/foo"
    replacement = root/"replacement"
    replacement.write("user\n")
    link = prefix/"bin/foo"
    link.dirname.mkpath
    FileUtils.ln_s(replacement, link)

    manifest = prefix/"var/homebrew/overlay-links.tsv"
    manifest.dirname.mkpath
    manifest.write("#{link}\t#{inherited_target}\n")

    expect(described_class.remove_inherited_prefix_link!(link)).to be(false)
    expect(link.readlink).to eq(replacement)
  end

  it "maps Keg.for through the active prefix but preserves direct parent paths" do
    parent_keg = add_parent_formula("foo", "1.0")
    base_bin = base_prefix/"bin/foo"
    base_bin.dirname.mkpath
    FileUtils.ln_s(parent_keg/"bin/foo", base_bin)
    environment_bin = prefix/"bin/foo"
    environment_bin.dirname.mkpath
    FileUtils.ln_s(base_bin, environment_bin)

    expect(Pathname(Keg.for(environment_bin).to_path)).to eq(HOMEBREW_CELLAR/"foo/1.0")
    expect(Pathname(Keg.for(base_bin).to_path)).to eq(parent_keg)
    expect(Pathname(Keg.new(parent_keg).to_path)).to eq(parent_keg)
  end
end
