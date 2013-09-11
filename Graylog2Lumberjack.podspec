Pod::Spec.new do |s|
  s.platform     = :ios, '5.0'
  s.name         = "Graylog2Lumberjack"
  s.version      = "0.0.2"
  s.summary      = "A graylog2 client for CocoaLumberjack."
  s.homepage     = "https://github.com/shakkame/Graylog2Lumberjack"
  s.license      = 'MIT'  
  s.author       = { "Shay Erlichmen" => "shay@shakka.me" }
  s.source       = { :git => "https://github.com/shakkame/Graylog2Lumberjack.git", :tag => "0.0.2" }
  s.source_files = 'Classes', 'Classes/Graylog2Logger.{h,m}'
  s.requires_arc = true
  s.dependency 'OpenUDID'
  s.dependency 'CocoaLumberjack'  
end
