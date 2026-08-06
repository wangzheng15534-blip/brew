# typed: true
# frozen_string_literal: true

require "uninstall"

RSpec.describe Homebrew::Uninstall do
  let(:dependency) do
    formula("dependency") do
      T.bind(self, T.class_of(Formula))
      url "f-1"
    end
  end

  let(:dependent_formula) do
    formula("dependent_formula") do
      T.bind(self, T.class_of(Formula))
      url "f-1"
      depends_on "dependency"
    end
  end

  let(:dependent_cask) do
    Cask::CaskLoader.load(+<<-RUBY)
      cask "dependent_cask" do
        version "1.0.0"

        url "c-1"
        depends_on formula: "dependency"
      end
    RUBY
  end

  let(:kegs_by_rack) { { dependency.rack => [Keg.new(dependency.latest_installed_prefix)] } }

  before do
    [dependency, dependent_formula].each do |f|
      f.latest_installed_prefix.mkpath
      Keg.new(f.latest_installed_prefix).optlink
    end

    tab = Tab.empty
    tab.homebrew_version = "1.1.6"
    tab.tabfile = dependent_formula.latest_installed_prefix/AbstractTab::FILENAME
    tab.runtime_dependencies = [
      { "full_name" => "dependency", "version" => "1" },
    ]
    tab.write

    Cask::Caskroom.path.join("dependent_cask", dependent_cask.version).mkpath

    stub_formula_loader dependency
    stub_formula_loader dependent_formula
    stub_cask_loader dependent_cask
  end

  describe "::handle_unsatisfied_dependents" do
    specify "when `ignore_dependencies` is false" do
      expect do
        described_class.handle_unsatisfied_dependents(kegs_by_rack)
      end.to output(/Error/).to_stderr

      expect(Homebrew).to have_failed
    end

    specify "when `ignore_dependencies` is true" do
      expect do
        described_class.handle_unsatisfied_dependents(kegs_by_rack, ignore_dependencies: true)
      end.not_to output.to_stderr

      expect(Homebrew).not_to have_failed
    end
  end

  describe "::uninstall_kegs with a native overlay" do
    let(:local_keg) { Keg.new(dependency.rack/"2") }
    let(:inherited_keg) { Keg.new(HOMEBREW_PREFIX/"base-cellar/dependency/1") }

    before do
      local_keg.to_path.mkpath
      inherited_keg.to_path.mkpath
      allow(Homebrew::Overlay).to receive(:active?).and_return(true)
      allow(Homebrew::Overlay).to receive(:base_prefix).and_return(HOMEBREW_PREFIX/"base")
      allow(Homebrew::Overlay).to receive(:inherited_keg?) do |path|
        Pathname(path) == inherited_keg.to_path
      end
      allow(described_class).to receive(:handle_unsatisfied_dependents)
      allow(described_class).to receive(:rm_pin)
    end

    it "removes only private kegs from a mixed rack with --force" do
      expect(local_keg).to receive(:unlink)
      expect(local_keg).to receive(:uninstall)
      expect(inherited_keg).not_to receive(:unlink)
      expect(inherited_keg).not_to receive(:uninstall)

      described_class.uninstall_kegs(
        { dependency.rack => [local_keg, inherited_keg] },
        force: true,
        ignore_dependencies: true,
      )
    end

    it "rejects an inherited-only rack with --force" do
      expect(inherited_keg).not_to receive(:unlink)
      expect(inherited_keg).not_to receive(:uninstall)

      expect do
        described_class.uninstall_kegs(
          { dependency.rack => [inherited_keg] },
          force: true,
          ignore_dependencies: true,
        )
      end.to output(/administrator Homebrew prefix/).to_stderr

      expect(Homebrew).to have_failed
    end
  end
end
