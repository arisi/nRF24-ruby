Gem::Specification.new do |s|
  s.name        = 'nRF24-ruby'
  s.version     = '0.0.5'
  s.date        = '2014-11-30'
  s.summary     = "Pure Ruby Driver and web-utilitity for Radio Chip nRF24 "
  s.description = "Pure Ruby Driver and Utilitity with Http-server for the Ultra Cheap Radio Chip nRF24 "
  s.authors     = ["Ari Siitonen"]
  s.email       = 'jalopuuverstas@gmail.com'
  s.executables << 'nRF24_udp.rb'
  s.files       = ["lib/nRF24-ruby.rb", "examples/nRF24-demo.rb"]
  s.files      += Dir['http/**/*']
  s.homepage    = 'https://github.com/arisi/nRF24-ruby'
  s.license     = 'MIT'
  s.add_runtime_dependency "minimal-http-ruby",[">= 0.0.3"]
  s.add_runtime_dependency "pi_piper",[">= 1.3.2"]
end
