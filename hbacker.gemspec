# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "hbacker/version"

Gem::Specification.new do |s|
  s.name        = "hbacker"
  s.version     = Hbacker::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Robert J. Berger Runa, Inc"]
  s.email       = ["rberger@runa.com"]
  s.homepage    = "http://blog.ibd.com"
  s.summary     = %q{Backup and Restore of HBase Cluster or individual tables}
  s.description = %q{Backup and Restore of HBase Cluster or individual tables using hadoop/hbase Mapreduce HBASE-1684}

  s.rubyforge_project = "hbacker"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
  s.add_development_dependency "rspec", "~> 2.5.0"
  s.add_development_dependency "cucumber"
  s.add_development_dependency "aruba"
  s.add_dependency "thor"
  s.add_dependency "fog", ">= 0.6.0"
  s.add_dependency "hbase-stargate"
end
