require "spec_helper"
require "fileutils"

RSpec.describe Mysigner::Config do
  let(:test_config_dir) { File.expand_path("~/.mysigner_test") }
  let(:test_config_file) { File.join(test_config_dir, "config.yml") }

  before do
    # Stub the constants to use test directory
    stub_const("Mysigner::Config::CONFIG_DIR", test_config_dir)
    stub_const("Mysigner::Config::CONFIG_FILE", test_config_file)
    
    # Clean up test directory
    FileUtils.rm_rf(test_config_dir) if Dir.exist?(test_config_dir)
  end

  after do
    # Clean up after tests
    FileUtils.rm_rf(test_config_dir) if Dir.exist?(test_config_dir)
  end

  describe "#initialize" do
    it "creates a new config with nil values" do
      config = Mysigner::Config.new
      expect(config.api_url).to be_nil
      expect(config.api_token).to be_nil
      expect(config.organization_id).to be_nil
    end

    it "loads existing config if file exists" do
      FileUtils.mkdir_p(test_config_dir)
      File.write(test_config_file, {
        'api_url' => 'http://localhost:3000',
        'api_token' => 'test_token',
        'organization_id' => 1
      }.to_yaml)

      config = Mysigner::Config.new
      expect(config.api_url).to eq('http://localhost:3000')
      expect(config.api_token).to eq('test_token')
      expect(config.organization_id).to eq(1)
    end
  end

  describe "#save" do
    it "creates config directory if it doesn't exist" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'test_token'
      config.save

      expect(Dir.exist?(test_config_dir)).to be true
    end

    it "saves configuration to file" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'test_token'
      config.organization_id = 1
      config.save

      expect(File.exist?(test_config_file)).to be true
      
      data = YAML.load_file(test_config_file)
      expect(data['api_url']).to eq('http://localhost:3000')
      expect(data['api_token']).to eq('test_token')
      expect(data['organization_id']).to eq(1)
    end

    it "sets file permissions to 0600" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      file_mode = File.stat(test_config_file).mode.to_s(8)[-3..-1]
      expect(file_mode).to eq('600')
    end
  end

  describe "#load" do
    it "returns false if config file doesn't exist" do
      config = Mysigner::Config.new
      expect(config.load).to be false
    end

    it "loads configuration from file" do
      FileUtils.mkdir_p(test_config_dir)
      File.write(test_config_file, {
        'api_url' => 'http://example.com',
        'api_token' => 'secret_token',
        'organization_id' => 42
      }.to_yaml)

      config = Mysigner::Config.new
      config.load

      expect(config.api_url).to eq('http://example.com')
      expect(config.api_token).to eq('secret_token')
      expect(config.organization_id).to eq(42)
    end
  end

  describe "#clear" do
    it "clears all config values" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'test_token'
      config.organization_id = 1
      config.clear

      expect(config.api_url).to be_nil
      expect(config.api_token).to be_nil
      expect(config.organization_id).to be_nil
    end

    it "deletes config file if it exists" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      expect(File.exist?(test_config_file)).to be true
      
      config.clear
      expect(File.exist?(test_config_file)).to be false
    end
  end

  describe "#exists?" do
    it "returns false when config file doesn't exist" do
      config = Mysigner::Config.new
      expect(config.exists?).to be false
    end

    it "returns true when config file exists" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.save

      expect(config.exists?).to be true
    end
  end

  describe "#valid?" do
    it "returns false when api_url is nil" do
      config = Mysigner::Config.new
      config.api_token = 'token'
      expect(config.valid?).to be false
    end

    it "returns false when api_token is nil" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      expect(config.valid?).to be false
    end

    it "returns false when api_url is empty" do
      config = Mysigner::Config.new
      config.api_url = ''
      config.api_token = 'token'
      expect(config.valid?).to be false
    end

    it "returns true when both api_url and api_token are set" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'token'
      expect(config.valid?).to be true
    end
  end

  describe "#to_h" do
    it "returns config as hash" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'token'
      config.organization_id = 1

      hash = config.to_h
      expect(hash).to eq({
        api_url: 'http://localhost:3000',
        api_token: 'token',
        organization_id: 1
      })
    end
  end

  describe "#display" do
    it "returns config with masked token" do
      config = Mysigner::Config.new
      config.api_url = 'http://localhost:3000'
      config.api_token = 'very_long_secret_token_12345'
      config.organization_id = 1

      display = config.display
      expect(display[:api_url]).to eq('http://localhost:3000')
      expect(display[:api_token]).to eq('very...2345')
      expect(display[:organization_id]).to eq(1)
    end

    it "shows (not set) for nil values" do
      config = Mysigner::Config.new
      display = config.display
      
      expect(display[:api_url]).to eq('(not set)')
      expect(display[:api_token]).to eq('(not set)')
      expect(display[:organization_id]).to eq('(not set)')
    end
  end
end

