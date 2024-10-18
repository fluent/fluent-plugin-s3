# encoding: utf-8
$:.push File.expand_path('../lib', __FILE__)

Gem::Specification.new do |gem|
  gem.name        = "fluent-plugin-s3"
  gem.description = "Amazon S3 output plugin for Fluentd event collector"
  gem.license     = "Apache-2.0"
  gem.homepage    = "https://github.com/fluent/fluent-plugin-s3"
  gem.summary     = gem.description
  gem.version     = File.read("VERSION").strip
  gem.authors     = ["Sadayuki Furuhashi", "Masahiro Nakagawa"]
  gem.email       = "frsyuki@gmail.com"
  #gem.platform    = Gem::Platform::RUBY
  gem.files       = `git ls-files`.split("\n")
  gem.test_files  = `git ls-files -- {test,spec,features}/*`.split("\n")
  gem.executables = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  gem.require_paths = ['lib']

  gem.add_dependency "fluentd", [">= 0.14.22", "< 2"]
  gem.add_dependency "aws-sdk-s3", "~> 1.60"
  gem.add_dependency "aws-sdk-sqs", "~> 1.23"
  gem.add_development_dependency "rake", ">= 0.9.2"
  gem.add_development_dependency "test-unit", ">= 3.0.8"
  gem.add_development_dependency "test-unit-rr", ">= 1.0.3"
  gem.add_development_dependency "timecop"
  # aws-sdk-core requires one of ox, oga, libxml, nokogiri or rexml,
  # and rexml is no longer default gem as of Ruby 3.0.
  gem.add_development_dependency "rexml"
  gem.add_development_dependency 'zstd-ruby'
end
