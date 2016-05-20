# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'svn_command_helper/version'

Gem::Specification.new do |spec|
  spec.name          = "svn_command_helper"
  spec.version       = SvnCommandHelper::VERSION
  spec.authors       = ["Narazaka"]
  spec.email         = ["info@narazaka.net"]

  spec.summary       = %q{svn command helper}
  spec.description   = %q{convenient svn commands}
  spec.homepage      = "https://github.com/SystemCommandHelperRB/svn_command_helper"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "system_command_helper"
  spec.add_development_dependency "bundler", "~> 1.11"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "yard", "~> 0.8.7"
  spec.add_development_dependency "simplecov", "~> 0.11"
  spec.add_development_dependency "codecov", "~> 0.1"
end
