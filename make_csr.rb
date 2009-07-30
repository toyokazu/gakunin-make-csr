#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# standard libraries
require 'yaml'
require 'find'
require 'shell'

# gem libraries
require 'rubygems'
require 'net/ssh/prompt'
include Net::SSH::Prompt

if (ARGV[0] == '-h' || ARGV[0] == '--help')
  puts "usage: make_csr.rb [config_file]"
  puts "./config.yml is used as default."
  exit 0
end

# config.yml format
# ---
# key_size: 1024
# random_files: 
# - ~/Downloads/hoge
# - ~/Downloads/foo
# - ~/Downloads/bar
# key_file: ./new_key.pem
# csr_file: ./new_csr.pem
# cert_descriptions:
#   C: JP
#   ST: .
#   L: Academe
#   O: Osaka University
#   OU: Cybermedia Center
#   CN: idp01.auth.cmc.osaka-u.ac.jp
#   emailAddress: .

# load config.yml file
config_file = nil
if ARGV[0].nil?
  config_file = "config.yml"
else
  config_file = ARGV[0]
end

config = {}
if !File.exist?(config_file)
  puts "config file #{config_file} is not found! using default values."
  puts "key_type: genrsa"
  puts "key_size: 1024"
  puts "random_files:"
  puts "- /etc/"
  puts "key_file: new_key.pem"
  puts "csr_files: new_csr.pem"
else
  config = YAML.load_file(config_file)
end
config["key_type"] ||= "genrsa"
config["key_size"] ||= 1024
config["random_files"] ||= ["/etc/"]
config["key_file"] ||= "new_key.pem"
config["csr_file"] ||= "new_csr.pem"
# certificate description defaults
config["cert_descriptions"] = {
  "C" => "JP",
  "ST" => ".",
  "L" => "Academe",
  "O" => "Sample University",
  "OU" => ".",
  "CN" => "idp.example.org",
  "emailAddress" => "."
}.merge(config["cert_descriptions"])

# === obtain random_files
# If the specified file is a directory, obtain files from
# the directory and add to the random_files. Finally,
# select 3 files from random_files.
random_files = []
Find.find(*config["random_files"]) do |f|
  if FileTest.file?(f)
    random_files << f
  end
end

if random_files.size < 3
  puts "specify more than 3 files"
  exit 1
end

# === select 3 files from random_files
selected_files = []
(1..3).each do |i|
  selected_files << random_files[rand(random_files.size)]
end

sh = Shell.new

# === create new rsa key
puts "creating new key #{config["key_file"]}"

password = nil
while password.nil?
  password = prompt("Password:", false)
  check_password = prompt("Retype Password:", false)
  if password != check_password
    password = nil
  end
end

sh.out(STDOUT) do
  system("openssl",
         config["key_type"],
         "-des3", 
         "-rand", selected_files.join(File::PATH_SEPARATOR),
         "-passout", "pass:#{password}",
         "-out", config["key_file"],
         config["key_size"].to_s)
end

# === create new csr
puts "creating new csr #{config["csr_file"]}"

subject = ""

# describe required dn keys in the order in openssl.conf
dn_keys = [ "C", "ST", "L", "O", "OU", "CN", "emailAddress" ]

dn_keys.each do |key|
  if config["cert_descriptions"][key] != '.' &&
      !config["cert_descriptions"][key].nil?
    subject = "#{subject}/#{key}=#{config["cert_descriptions"][key]}"
  end
end

sh.out(STDOUT) do
  system("openssl",
         "req",
         "-new",
         "-subj", subject,
         "-key", config["key_file"],
         "-out", config["csr_file"],
         "-passin", "pass:#{password}")
end
