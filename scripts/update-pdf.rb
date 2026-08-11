#!/usr/bin/env ruby
# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "timeout"
require "uri"
require "rubygems/version"

module PdfFormulaUpdate
  FORMULA = "pdf"
  FORMULA_REF = "signed-page/tap/pdf"
  FORMULA_PATH = "Formula/pdf.rb"
  TEMPLATE_PATH = "templates/pdf.rb.erb"
  SOURCE_REPOSITORY = "signed-page/pdf"
  OCI_REPOSITORY = "ghcr.io/signed-page/tap/pdf"
  BOTTLE_ROOT_URL = "https://ghcr.io/v2/signed-page/tap"
  BOTTLE_TAGS = %w[arm64_sonoma arm64_linux x86_64_linux].freeze
  HEX_256 = /\A[0-9a-f]{64}\z/
  DIGEST_256 = /\Asha256:[0-9a-f]{64}\z/
  SEMVER = /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/

  class Error < StandardError; end
  class MetadataError < Error; end
  class CommandError < Error; end

  Release = Struct.new(
    :version,
    :source_url,
    :source_sha256,
    :index_digest,
    :bottles,
    keyword_init: true,
  )

  FormulaState = Struct.new(
    :version,
    :source_url,
    :source_sha256,
    :bottle_root_url,
    :bottle_rebuild,
    :bottles,
    keyword_init: true,
  )

  class UniqueHash < Hash
    def []=(key, value)
      raise MetadataError, "duplicate JSON key #{key.inspect}" if key?(key)

      super
    end
  end

  module StrictJSON
    module_function

    def load_file(path)
      parse(File.binread(path), path.to_s)
    rescue Errno::ENOENT
      raise MetadataError, "metadata file does not exist: #{path}"
    rescue Errno::EACCES => e
      raise MetadataError, "cannot read metadata file #{path}: #{e.message}"
    end

    def parse(text, label)
      JSON.parse(text, object_class: UniqueHash, create_additions: false)
    rescue JSON::ParserError, MetadataError => e
      raise MetadataError, "invalid JSON in #{label}: #{e.message}"
    end
  end

  class Shape
    def hash(value, path)
      return value if value.is_a?(Hash)

      raise MetadataError, "#{path} must be an object"
    end

    def string(value, path)
      return value if value.is_a?(String) && !value.empty?

      raise MetadataError, "#{path} must be a non-empty string"
    end

    def integer(value, path, minimum: 0)
      return value if value.is_a?(Integer) && value >= minimum

      raise MetadataError, "#{path} must be an integer >= #{minimum}"
    end

    def exact_keys(value, expected, path)
      actual = hash(value, path).keys.sort
      wanted = expected.sort
      return if actual == wanted

      raise MetadataError, "#{path} keys must be exactly #{wanted.join(', ')}; got #{actual.join(', ')}"
    end

    def permitted_keys(value, required:, optional:, path:)
      object = hash(value, path)
      missing = required - object.keys
      extra = object.keys - required - optional
      raise MetadataError, "#{path} is missing keys: #{missing.join(', ')}" unless missing.empty?
      raise MetadataError, "#{path} has unsupported keys: #{extra.join(', ')}" unless extra.empty?
    end

    def bare_sha(value, path)
      digest = string(value, path)
      raise MetadataError, "#{path} must be 64 lowercase hexadecimal characters" unless HEX_256.match?(digest)

      digest
    end

    def digest(value, path)
      digest = string(value, path)
      raise MetadataError, "#{path} must be a sha256:<64 lowercase hex> digest" unless DIGEST_256.match?(digest)

      digest
    end
  end

  class Metadata
    FORMULA_KEYS = %w[name pkg_version path].freeze
    FORMULA_OPTIONAL_KEYS = %w[desc homepage license tap_git_path tap_git_remote tap_git_revision].freeze
    BOTTLE_KEYS = %w[root_url rebuild tags].freeze
    BOTTLE_OPTIONAL_KEYS = %w[cellar date prefix].freeze
    TAG_KEYS = %w[sha256].freeze
    TAG_OPTIONAL_KEYS = %w[all_files cellar filename installed_size local_filename path_exec_files sbom tab].freeze

    def initialize
      @shape = Shape.new
    end

    def load(release_path, bottle_path)
      release_json = StrictJSON.load_file(release_path)
      release = validate_release(release_json)
      bottle_json = StrictJSON.load_file(bottle_path)
      validate_bottle_json(bottle_json, release)
      release
    end

    private

    def validate_release(document)
      @shape.exact_keys(document, %w[bottles formula oci schema source version], "release")
      raise MetadataError, "release.schema must equal 1" unless document["schema"] == 1
      raise MetadataError, "release.formula must equal #{FORMULA.inspect}" unless document["formula"] == FORMULA

      version = validate_version(document["version"], "release.version")
      source_url, source_sha256 = validate_source(document["source"], version)
      index_digest = validate_oci(document["oci"])
      bottles = validate_release_bottles(document["bottles"])
      Release.new(
        version: version,
        source_url: source_url,
        source_sha256: source_sha256,
        index_digest: index_digest,
        bottles: bottles,
      )
    end

    def validate_version(value, path)
      version = @shape.string(value, path)
      raise MetadataError, "#{path} must be a stable semantic version" unless SEMVER.match?(version)

      version
    end

    def validate_source(source, version)
      @shape.exact_keys(source, %w[filename sha256], "release.source")
      filename = @shape.string(source["filename"], "release.source.filename")
      expected = "pdf-sign-#{version}-source.tar.gz"
      raise MetadataError, "release.source.filename must equal #{expected.inspect}" unless filename == expected

      url = "https://github.com/#{SOURCE_REPOSITORY}/releases/download/v#{version}/#{filename}"
      validate_source_url(url, version, filename)
      [url, @shape.bare_sha(source["sha256"], "release.source.sha256")]
    end

    def validate_source_url(url, version, filename)
      uri = URI.parse(url)
      expected_path = "/#{SOURCE_REPOSITORY}/releases/download/v#{version}/#{filename}"
      valid = uri.scheme == "https" && uri.host == "github.com" && uri.path == expected_path &&
              uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      raise MetadataError, "source URL must use the canonical signed-page/pdf GitHub release path" unless valid
    end

    def validate_oci(oci)
      @shape.exact_keys(oci, %w[indexDigest repository], "release.oci")
      raise MetadataError, "release.oci.repository must equal #{OCI_REPOSITORY.inspect}" unless oci["repository"] == OCI_REPOSITORY

      @shape.digest(oci["indexDigest"], "release.oci.indexDigest")
    end

    def validate_release_bottles(bottles)
      @shape.exact_keys(bottles, BOTTLE_TAGS, "release.bottles")
      BOTTLE_TAGS.to_h do |tag|
        bottle = @shape.hash(bottles[tag], "release.bottles.#{tag}")
        validate_release_bottle(bottle, tag)
        [tag, bottle]
      end
    end

    def validate_release_bottle(bottle, tag)
      path = "release.bottles.#{tag}"
      @shape.exact_keys(bottle, %w[cellar installedSize manifestDigest sha256 size], path)
      @shape.bare_sha(bottle["sha256"], "#{path}.sha256")
      @shape.digest(bottle["manifestDigest"], "#{path}.manifestDigest")
      @shape.integer(bottle["size"], "#{path}.size", minimum: 1)
      @shape.integer(bottle["installedSize"], "#{path}.installedSize", minimum: 1)
      raise MetadataError, "#{path}.cellar must equal any_skip_relocation" unless bottle["cellar"] == "any_skip_relocation"
    end

    def validate_bottle_json(document, release)
      @shape.exact_keys(document, [FORMULA], "bottle metadata")
      entry = @shape.hash(document[FORMULA], "bottle metadata.#{FORMULA}")
      @shape.exact_keys(entry, %w[bottle formula], "bottle metadata.#{FORMULA}")
      validate_formula_identity(entry["formula"], release.version)
      validate_bottle_payload(entry["bottle"], release)
    end

    def validate_formula_identity(formula, version)
      path = "bottle metadata.#{FORMULA}.formula"
      @shape.permitted_keys(formula, required: FORMULA_KEYS, optional: FORMULA_OPTIONAL_KEYS, path: path)
      raise MetadataError, "#{path}.name must equal #{FORMULA.inspect}" unless formula["name"] == FORMULA
      raise MetadataError, "#{path}.pkg_version disagrees with release.version" unless formula["pkg_version"] == version
      expected = "Library/Taps/signed-page/homebrew-tap/#{FORMULA_PATH}"
      raise MetadataError, "#{path}.path must equal #{expected.inspect}" unless formula["path"] == expected
      if formula.key?("tap_git_path") && formula["tap_git_path"] != FORMULA_PATH
        raise MetadataError, "#{path}.tap_git_path must equal #{FORMULA_PATH.inspect}"
      end
    end

    def validate_bottle_payload(bottle, release)
      path = "bottle metadata.#{FORMULA}.bottle"
      @shape.permitted_keys(bottle, required: BOTTLE_KEYS, optional: BOTTLE_OPTIONAL_KEYS, path: path)
      raise MetadataError, "#{path}.root_url must equal #{BOTTLE_ROOT_URL.inspect}" unless bottle["root_url"] == BOTTLE_ROOT_URL
      raise MetadataError, "#{path}.rebuild must equal 0" unless bottle["rebuild"] == 0

      tags = @shape.hash(bottle["tags"], "#{path}.tags")
      @shape.exact_keys(tags, BOTTLE_TAGS, "#{path}.tags")
      BOTTLE_TAGS.each { |tag| validate_bottle_tag(tags[tag], bottle["cellar"], release.bottles.fetch(tag), tag) }
    end

    def validate_bottle_tag(tag_data, common_cellar, release_bottle, tag)
      path = "bottle metadata.#{FORMULA}.bottle.tags.#{tag}"
      @shape.permitted_keys(tag_data, required: TAG_KEYS, optional: TAG_OPTIONAL_KEYS, path: path)
      sha256 = @shape.bare_sha(tag_data["sha256"], "#{path}.sha256")
      raise MetadataError, "#{path}.sha256 disagrees with release metadata" unless sha256 == release_bottle["sha256"]

      cellar = tag_data.fetch("cellar", common_cellar)
      raise MetadataError, "#{path}.cellar must equal any_skip_relocation" unless cellar == "any_skip_relocation"
      return unless tag_data.key?("installed_size")
      return if tag_data["installed_size"] == release_bottle["installedSize"]

      raise MetadataError, "#{path}.installed_size disagrees with release metadata"
    end
  end

  class CommandRunner
    TIMEOUT_SECONDS = 600
    MAX_DIAGNOSTIC_BYTES = 16_384

    def initialize(root)
      @root = root
    end

    def capture!(*command)
      stdout, stderr, status = Timeout.timeout(TIMEOUT_SECONDS) do
        Open3.capture3({ "HOMEBREW_NO_AUTO_UPDATE" => "1" }, *command, chdir: @root.to_s)
      end
      return stdout if status.success?

      diagnostic = [stdout, stderr].reject(&:empty?).join("\n").byteslice(0, MAX_DIAGNOSTIC_BYTES)
      raise CommandError, "#{command.first} exited #{status.exitstatus}: #{diagnostic}"
    rescue Timeout::Error
      raise CommandError, "#{command.first} exceeded #{TIMEOUT_SECONDS} seconds"
    rescue Errno::ENOENT
      raise CommandError, "required command not found: #{command.first}"
    end
  end

  class FormulaInspector
    def initialize(runner, brew)
      @runner = runner
      @brew = brew
      @shape = Shape.new
    end

    def read(formula_path)
      output = @runner.capture!(@brew, "info", "--json=v2", "--formula", formula_path.to_s)
      document = StrictJSON.parse(output, "brew info output")
      formulae = document["formulae"]
      unless formulae.is_a?(Array) && formulae.length == 1
        raise Error, "brew info must return exactly one formula"
      end

      build_state(@shape.hash(formulae.first, "brew info formula"))
    end

    private

    def build_state(formula)
      raise Error, "brew resolved the wrong formula" unless formula["name"] == FORMULA

      stable_url = @shape.hash(formula.dig("urls", "stable"), "brew info urls.stable")
      bottle = formula.dig("bottle", "stable") || {}
      FormulaState.new(
        version: formula.dig("versions", "stable"),
        source_url: stable_url["url"],
        source_sha256: stable_url["checksum"],
        bottle_root_url: bottle["root_url"],
        bottle_rebuild: bottle["rebuild"],
        bottles: bottle_files(bottle["files"] || {}),
      )
    end

    def bottle_files(files)
      @shape.hash(files, "brew info bottle files").to_h do |tag, data|
        entry = @shape.hash(data, "brew info bottle files.#{tag}")
        [tag, { "sha256" => entry["sha256"], "cellar" => entry["cellar"] }]
      end
    end
  end

  class Updater
    def initialize(root: Pathname(__dir__).parent, runner: nil, output: $stdout)
      @root = Pathname(root).expand_path
      @runner = runner || CommandRunner.new(@root)
      @output = output
      @brew = ENV.fetch("HOMEBREW_BREW_FILE", "brew")
      @formula_path = @root/FORMULA_PATH
      @template_path = @root/TEMPLATE_PATH
      @inspector = FormulaInspector.new(@runner, @brew)
    end

    def run(release_path, bottle_path)
      @snapshot = nil
      release_path = Pathname(release_path).expand_path
      bottle_path = Pathname(bottle_path).expand_path
      release = Metadata.new.load(release_path, bottle_path)
      assert_formula_clean!

      if @formula_path.exist?
        action = update_existing(release, bottle_path)
        return action if action == :unchanged
      else
        mutate_formula { render_formula(release) }
        merge_bottles(bottle_path)
      end

      assert_final_state!(@inspector.read(@formula_path), release)
      @snapshot = nil
      @output.puts "Updated #{FORMULA_PATH} to #{release.version}"
      :updated
    rescue Error
      restore_formula if defined?(@snapshot)
      raise
    end

    private

    def update_existing(release, bottle_path)
      current = @inspector.read(@formula_path)
      unless current.version.is_a?(String) && SEMVER.match?(current.version)
        raise Error, "existing Formula version is not a stable semantic version"
      end
      comparison = Gem::Version.new(release.version) <=> Gem::Version.new(current.version)
      raise Error, "refusing to downgrade #{FORMULA} from #{current.version} to #{release.version}" if comparison.negative?

      if comparison.zero?
        raise Error, "same-version metadata conflicts with Formula/#{FORMULA}.rb" unless state_matches?(current, release)

        @output.puts "#{FORMULA} #{release.version} already has identical release metadata"
        return :unchanged
      end

      mutate_formula do
        bump_formula(release)
        merge_bottles(bottle_path)
      end
      :updated
    end

    def mutate_formula
      take_snapshot
      yield
    rescue StandardError
      restore_formula
      raise
    end

    def take_snapshot
      @snapshot = if @formula_path.exist?
        { existed: true, content: @formula_path.binread, mode: @formula_path.stat.mode & 0o777 }
      else
        { existed: false }
      end
    end

    def restore_formula
      return unless @snapshot

      if @snapshot[:existed]
        atomic_write(@formula_path, @snapshot[:content], @snapshot[:mode])
      else
        @formula_path.delete if @formula_path.exist?
        @formula_path.dirname.rmdir if @formula_path.dirname.directory? && @formula_path.dirname.children.empty?
      end
      @snapshot = nil
    end

    def render_formula(release)
      template = ERB.new(@template_path.binread, trim_mode: "-")
      content = template.result_with_hash(
        version: release.version,
        source_url: release.source_url,
        source_sha256: release.source_sha256,
      )
      atomic_write(@formula_path, content, 0o644)
    rescue Errno::ENOENT
      raise Error, "missing Formula template: #{@template_path}"
    end

    def atomic_write(path, content, mode)
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".#{path.basename}", ".tmp"], path.dirname) do |temporary|
        temporary.binmode
        temporary.write(content)
        temporary.flush
        temporary.fsync
        temporary.chmod(mode)
        File.rename(temporary.path, path)
      end
    end

    def bump_formula(release)
      @runner.capture!(
        @brew,
        "bump-formula-pr",
        "--write-only",
        "--no-audit",
        "--version=#{release.version}",
        "--url=#{release.source_url}",
        "--sha256=#{release.source_sha256}",
        FORMULA_REF,
      )
    end

    def merge_bottles(bottle_path)
      @runner.capture!(@brew, "bottle", "--merge", "--write", "--no-commit", bottle_path.to_s)
    end

    def assert_formula_clean!
      status = @runner.capture!(
        "git", "-C", @root.to_s, "status", "--porcelain=v1", "--untracked-files=all", "--", FORMULA_PATH,
      )
      raise Error, "refusing to overwrite dirty #{FORMULA_PATH}" unless status.empty?
    end

    def assert_final_state!(state, release)
      raise Error, "Homebrew parsed version #{state.version.inspect}, expected #{release.version}" unless state.version == release.version
      raise Error, "Homebrew parsed an unexpected source URL" unless state.source_url == release.source_url
      raise Error, "Homebrew parsed an unexpected source SHA-256" unless state.source_sha256 == release.source_sha256
      raise Error, "Homebrew parsed an unexpected bottle root URL" unless state.bottle_root_url == BOTTLE_ROOT_URL
      raise Error, "Homebrew parsed an unexpected bottle rebuild" unless state.bottle_rebuild == 0
      raise Error, "Homebrew parsed bottle metadata that disagrees with the release" unless bottle_state_matches?(state, release)
    end

    def state_matches?(state, release)
      state.version == release.version &&
        state.source_url == release.source_url &&
        state.source_sha256 == release.source_sha256 &&
        state.bottle_root_url == BOTTLE_ROOT_URL &&
        state.bottle_rebuild == 0 &&
        bottle_state_matches?(state, release)
    end

    def bottle_state_matches?(state, release)
      return false unless state.bottles.keys.sort == BOTTLE_TAGS.sort

      BOTTLE_TAGS.all? do |tag|
        parsed = state.bottles.fetch(tag)
        parsed["sha256"] == release.bottles.fetch(tag)["sha256"] &&
          parsed["cellar"].to_s.delete_prefix(":") == "any_skip_relocation"
      end
    end
  end

  module CLI
    module_function

    def run(arguments)
      unless arguments.length == 2
        warn "Usage: scripts/update-pdf.rb <release.json> <pdf.bottle.json>"
        return 64
      end

      Updater.new.run(arguments.fetch(0), arguments.fetch(1))
      0
    rescue Error, ArgumentError => e
      warn "update-pdf: #{e.message}"
      1
    end
  end
end

exit PdfFormulaUpdate::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
