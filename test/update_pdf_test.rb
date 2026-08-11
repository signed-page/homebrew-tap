# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "stringio"
require "tmpdir"

require_relative "../scripts/update-pdf"

class UpdatePdfTest < Minitest::Test
  FORMULA = PdfFormulaUpdate::FORMULA
  TAGS = PdfFormulaUpdate::BOTTLE_TAGS

  class HomebrewContractRunner
    attr_reader :commands

    def initialize(root)
      @root = Pathname(root)
      @commands = []
      @brew = ENV.fetch("HOMEBREW_BREW_FILE", "brew")
    end

    def capture!(*command)
      @commands << command
      return "" if command.first == "git"
      return brew_info(command) if command[1] == "info"
      return simulate_bump(command) if command[1] == "bump-formula-pr"
      return simulate_bottle_merge(command) if command[1] == "bottle"

      raise "unexpected command: #{command.inspect}"
    end

    private

    def brew_info(_command)
      script = <<~'RUBY'
        require "formulary"
        require "json"
        require "pathname"

        path = Pathname.new(ARGV.fetch(0))
        formula = Formulary.from_contents("pdf", path, path.binread)
        puts JSON.generate("formulae" => [formula.to_hash])
      RUBY
      stdout, stderr, status = Open3.capture3(
        { "HOMEBREW_NO_AUTO_UPDATE" => "1" },
        @brew,
        "ruby",
        "-e",
        script,
        formula_path.to_s,
        chdir: @root.to_s,
      )
      raise "brew info failed: #{stderr}" unless status.success?

      stdout
    end

    def simulate_bump(command)
      flags = command.each_with_object({}) do |argument, values|
        next unless argument.start_with?("--")

        key, value = argument.split("=", 2)
        values[key] = value || true
      end
      source = formula_path.binread
      source.sub!(/^  url ".*"$/, "  url \"#{flags.fetch('--url')}\"")
      source.sub!(/^  sha256 ".*"$/, "  sha256 \"#{flags.fetch('--sha256')}\"")
      raise "test bump did not update Formula" unless source.include?(flags.fetch("--version"))

      formula_path.binwrite(source)
      ""
    end

    def simulate_bottle_merge(command)
      metadata_path = Pathname(command.last)
      bottle = JSON.parse(metadata_path.binread).fetch(FORMULA).fetch("bottle")
      source = formula_path.binread
      source.sub!(/\n  bottle do\n.*?\n  end\n/m, "\n")
      source.sub!(/^  depends_on/) { "#{bottle_block(bottle)}\n\n  depends_on" }
      formula_path.binwrite(source)
      ""
    end

    def bottle_block(bottle)
      lines = ["  bottle do", "    root_url \"#{bottle.fetch('root_url')}\""]
      bottle.fetch("tags").each do |tag, data|
        lines << "    sha256 cellar: :any_skip_relocation, #{tag}: \"#{data.fetch('sha256')}\""
      end
      lines << "  end"
      lines.join("\n")
    end

    def formula_path
      @root/PdfFormulaUpdate::FORMULA_PATH
    end
  end

  def setup
    @temporary = Dir.mktmpdir("update-pdf-test-")
    @root = Pathname(@temporary)
    FileUtils.mkdir_p(@root/"templates")
    FileUtils.cp(Pathname(__dir__).parent/"templates/pdf.rb.erb", @root/"templates/pdf.rb.erb")
    @runner = HomebrewContractRunner.new(@root)
    @output = StringIO.new
    @updater = PdfFormulaUpdate::Updater.new(root: @root, runner: @runner, output: @output)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def test_first_release_renders_formula_then_merges_all_bottles
    release_path, bottle_path = write_metadata(version: "1.2.3")

    assert_equal :updated, @updater.run(release_path, bottle_path)

    info = formula_info
    assert_formula_contract(info, "1.2.3")
    assert_equal TAGS.sort, info.dig("bottle", "stable", "files").keys.sort
    refute @runner.commands.any? { |command| command[1] == "bump-formula-pr" }
    assert @runner.commands.any? { |command| command[1] == "bottle" }
  end

  def test_version_bump_uses_homebrew_and_preserves_authored_formula_behavior
    first_release, first_bottles = write_metadata(version: "1.2.3")
    @updater.run(first_release, first_bottles)
    @runner.commands.clear
    next_release, next_bottles = write_metadata(version: "1.2.4", seed: 7)

    assert_equal :updated, @updater.run(next_release, next_bottles)

    info = formula_info
    assert_formula_contract(info, "1.2.4")
    bump = @runner.commands.find { |command| command[1] == "bump-formula-pr" }
    assert_includes bump, "--write-only"
    assert_includes bump, "--no-audit"
    assert_includes bump, "signed-page/tap/pdf"
  end

  def test_rejects_malformed_digest
    release_path, bottle_path = write_metadata(version: "1.2.3") do |release, _bottle|
      release.fetch("source")["sha256"] = "ABC123"
    end

    error = assert_raises(PdfFormulaUpdate::MetadataError) { @updater.run(release_path, bottle_path) }
    assert_match(/64 lowercase hexadecimal/, error.message)
    refute (@root/"Formula/pdf.rb").exist?
  end

  def test_rejects_missing_platform
    release_path, bottle_path = write_metadata(version: "1.2.3") do |release, bottle|
      release.fetch("bottles").delete("arm64_linux")
      bottle.fetch(FORMULA).fetch("bottle").fetch("tags").delete("arm64_linux")
    end

    error = assert_raises(PdfFormulaUpdate::MetadataError) { @updater.run(release_path, bottle_path) }
    assert_match(/release\.bottles keys must be exactly/, error.message)
  end

  def test_rejects_same_version_with_different_release_metadata
    first_release, first_bottles = write_metadata(version: "1.2.3")
    @updater.run(first_release, first_bottles)
    conflicting_release, conflicting_bottles = write_metadata(version: "1.2.3", seed: 8)

    error = assert_raises(PdfFormulaUpdate::Error) do
      @updater.run(conflicting_release, conflicting_bottles)
    end
    assert_match(/same-version metadata conflicts/, error.message)
  end

  def test_rejects_lower_version
    first_release, first_bottles = write_metadata(version: "1.2.3")
    @updater.run(first_release, first_bottles)
    lower_release, lower_bottles = write_metadata(version: "1.2.2", seed: 9)

    error = assert_raises(PdfFormulaUpdate::Error) { @updater.run(lower_release, lower_bottles) }
    assert_match(/refusing to downgrade pdf from 1\.2\.3 to 1\.2\.2/, error.message)
  end

  private

  def formula_info
    document = JSON.parse(@runner.capture!(
      ENV.fetch("HOMEBREW_BREW_FILE", "brew"),
      "info",
      "--json=v2",
      "--formula",
      (@root/"Formula/pdf.rb").to_s,
    ))
    document.fetch("formulae").fetch(0)
  end

  def assert_formula_contract(info, version)
    assert_equal "pdf", info.fetch("name")
    assert_equal version, info.dig("versions", "stable")
    assert_equal "https://signed.page", info.fetch("homepage")
    assert_equal "GPL-3.0-only", info.fetch("license")
    assert_equal %w[capnp rust], info.fetch("build_dependencies").sort
    behavior = formula_behavior
    assert_equal "Pdf", behavior.fetch("install_owner").split("::").last
    assert_equal "Pdf", behavior.fetch("test_owner").split("::").last
  end

  def formula_behavior
    script = <<~'RUBY'
      require "formulary"
      require "json"
      require "pathname"

      path = Pathname.new(ARGV.fetch(0))
      formula = Formulary.from_contents("pdf", path, path.binread)
      puts JSON.generate(
        install_owner: formula.method(:install).owner.name,
        test_owner: formula.method(:test).owner.name,
      )
    RUBY
    stdout, stderr, status = Open3.capture3(
      { "HOMEBREW_NO_AUTO_UPDATE" => "1" },
      ENV.fetch("HOMEBREW_BREW_FILE", "brew"),
      "ruby",
      "-e",
      script,
      (@root/"Formula/pdf.rb").to_s,
    )
    raise "brew ruby failed: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def write_metadata(version:, seed: 1)
    release = release_metadata(version, seed)
    bottle = bottle_metadata(release)
    yield release, bottle if block_given?
    release_path = @root/"release-#{version}-#{seed}.json"
    bottle_path = @root/"pdf-#{version}-#{seed}.bottle.json"
    release_path.write(JSON.generate(release))
    bottle_path.write(JSON.generate(bottle))
    [release_path, bottle_path]
  end

  def release_metadata(version, seed)
    hashes = synthetic_hashes(seed)
    bottles = TAGS.each_with_index.to_h do |tag, index|
      [
        tag,
        {
          "sha256" => hashes.fetch(index),
          "manifestDigest" => "sha256:#{hashes.fetch(index + 3)}",
          "size" => 1_000 + index,
          "installedSize" => 2_000 + index,
          "cellar" => "any_skip_relocation",
        },
      ]
    end
    {
      "schema" => 1,
      "formula" => FORMULA,
      "version" => version,
      "source" => {
        "filename" => "pdf-sign-#{version}-source.tar.gz",
        "sha256" => hashes.fetch(6),
      },
      "oci" => {
        "repository" => "ghcr.io/signed-page/tap/pdf",
        "indexDigest" => "sha256:#{hashes.fetch(7)}",
      },
      "bottles" => bottles,
    }
  end

  def bottle_metadata(release)
    tags = release.fetch("bottles").to_h do |tag, data|
      [tag, { "sha256" => data.fetch("sha256"), "installed_size" => data.fetch("installedSize") }]
    end
    {
      FORMULA => {
        "formula" => {
          "name" => FORMULA,
          "pkg_version" => release.fetch("version"),
          "path" => "Library/Taps/signed-page/homebrew-tap/Formula/pdf.rb",
        },
        "bottle" => {
          "root_url" => "https://ghcr.io/v2/signed-page/tap",
          "cellar" => "any_skip_relocation",
          "rebuild" => 0,
          "tags" => tags,
        },
      },
    }
  end

  def synthetic_hashes(seed)
    alphabet = ("0".."9").to_a + ("a".."f").to_a
    Array.new(8) { |index| alphabet.fetch((seed + index) % alphabet.length) * 64 }
  end
end
