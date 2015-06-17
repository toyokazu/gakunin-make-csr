#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# standard libraries
require 'yaml'
require 'find'
require 'shell'
require 'fileutils'
require 'pathname'

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
# key_type: rsa
# key_size: 2048
# random_files: 
# - ~/Downloads/hoge
# - ~/Downloads/foo
# - ~/Downloads/bar
# key_file: ./new_key.pem
# req_file: ./new_req.pem
# p12_file: ./new_p12.p12 (only for x509)
# req_type: csr | x509
# req_days: 30 (only for x509)
# cert_descriptions:
#   C: JP
#   ST: .
#   L: Academe2
#   O: Osaka University
#   OU: Cybermedia Center
#   CN: idp01.auth.cmc.osaka-u.ac.jp
#   emailAddress: .
# debug: true

# load config.yml file
config_file = nil
if ARGV[0].nil?
  config_file = "config.yml"
else
  config_file = ARGV[0]
end

$config = {}
if !File.exist?(config_file)
  puts "config file #{config_file} is not found! using default values."
  puts "key_type: rsa"
  puts "key_size: 2048"
  puts "digest: sha256"
  puts "random_files:"
  puts "- /etc/"
  puts "key_file: new_key.pem"
  puts "req_file: new_req.pem"
  puts "req_type: csr"
else
  $config = YAML.load_file(config_file)
end
$config["key_type"] ||= "rsa"
$config["key_size"] ||= 2048
$config["digest"] ||= "sha256"
$config["random_files"] ||= ["/etc/"]
$config["key_file"] ||= "new_key.pem"
$config["req_file"] ||= "new_req.pem"
$config["debug"] ||= false
# certificate description defaults
$config["cert_descriptions"] = {
  "C" => "JP",
  "ST" => ".",
  "L" => "Academe2",
  "O" => "Sample University",
  "OU" => ".",
  "CN" => "idp.example.org",
  "emailAddress" => "."
}.merge($config["cert_descriptions"])


# === get_password method
#
def get_password
  password = nil
  while password.nil?
    password = prompt("Password:", false)
    check_password = prompt("Retype Password:", false)
    if password != check_password
      password = nil
    end
  end
  password
end

def null_password?(pass)
  null_password = false
  password = pass
  if pass.empty?
    null_password = true
    password = "1234ABCD"
  end
  [password, null_password]
end


# === obtain random_files
# If the specified file is a directory, obtain files from
# the directory and add to the random_files. Finally,
# select 3 files from random_files.
random_files = []
Find.find(*$config["random_files"]) do |f|
  if FileTest.file?(f)
    random_files << f
  end
end

if random_files.size < 3
  puts "specify more than 3 files"
  exit 1
end

# === select 3 files from random_files
$selected_files = []
(1..3).each do |i|
  $selected_files << random_files[rand(random_files.size)]
end

$sh = Shell.new

def sh_exec(&block)
  if $config["debug"]
    puts "debug mode"
    $sh.out(STDOUT, &block)
  else
    yield(block)
  end
end

# === create new rsa key
puts "creating new key #{$config["key_file"]}"

$password = get_password
$password, $null_password = null_password?($password)

sh_exec do
  args = [
    "openssl",
    "gen#{$config["key_type"]}",
    "-des3", 
    "-rand", $selected_files.join(File::PATH_SEPARATOR),
    "-out", $config["key_file"],
    "-passout", "pass:#{$password}",
    $config["key_size"].to_s
  ]
  system(*args)
end

if $null_password
  pathname = Pathname.new($config["key_file"])
  tmp_filename = "#{pathname.dirname}/tmp_#{pathname.basename}"
  sh_exec do
    args = [
      "openssl",
      $config["key_type"],
      "-in", $config["key_file"],
      "-passin", "pass:#{$password}",
      "-out", tmp_filename
    ]
    system(*args)
  end
  FileUtils.mv(tmp_filename, $config["key_file"])
end

FileUtils.chmod("go-rwx", $config["key_file"])

# === create new csr
case $config["req_type"]
when "csr"
  puts "creating new csr #{$config["req_file"]}"
when "x509"
  puts "creating new self-signed certificate #{$config["req_file"]}"
end

$subject = ""

# describe required dn keys in the order in openssl.conf
dn_keys = [ "C", "ST", "L", "O", "OU", "CN", "emailAddress" ]

dn_keys.each do |key|
  if $config["cert_descriptions"][key] != '.' &&
      !$config["cert_descriptions"][key].nil?
    $subject = "#{$subject}/#{key}=#{$config["cert_descriptions"][key]}"
  end
end

sh_exec do
  args = [
    "openssl",
    "req",
    "-new",
    "-subj", $subject,
    "-#{$config["digest"]}",
    "-key", $config["key_file"],
    "-out", $config["req_file"]
  ]
  if !$null_password
    args << "-passin"
    args << "pass:#{$password}"
  end
  if $config["req_type"] == "x509"
    args << "-x509"
    if !$config["req_days"].nil?
      args << "-days"
      args << $config["req_days"].to_s
    end
  end
  if !$config["openssl_conf"].nil?
    args << "-config"
    args << $config["openssl_conf"].to_s
    if !$config["openssl_extensions"].nil?
      args << "-extensions"
      args << $config["openssl_extensions"].to_s
    end
  end
  system(*args)
end

# === create p12 file
if $config["req_type"] == "x509" && $config["p12_file"]
  puts "creating new PKCS#12 file #{$config["p12_file"]}"
  $p12_pass = get_password

  sh_exec do
    args = [
      "openssl",
      "pkcs12",
      "-export",
      "-in", $config["req_file"],
      "-inkey", $config["key_file"],
      "-passout", "pass:#{$p12_pass}",
      "-out", $config["p12_file"]
    ]
    if !$null_password
      args << "-passin"
      args << "pass:#{$password}"
    end
    system(*args)
  end
end
