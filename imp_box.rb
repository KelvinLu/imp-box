#!/usr/bin/env ruby

require 'logger'
require 'open3'
require 'yaml'

MODES = %i[
  synchronize
  clone
  move
]

LOGGER = Logger.new($stderr)

def main(args = ARGV)
  raise 'Extraneous arguments given' if args.length > 2

  destination_base = args[0]

  raise 'File path to base destination directory must be given' if destination_base.nil?

  destination_base = File.expand_path(destination_base)

  unless File.exist?(destination_base) && File.directory?(destination_base)
    raise "Directory '#{destination_base}' does not exist"
  end

  manifest_filepath = args[1]

  raise 'File path to manifest must be given' if manifest_filepath.nil?

  manifest_filepath = File.expand_path(manifest_filepath)

  unless File.exist?(manifest_filepath) && File.file?(manifest_filepath)
    raise "File '#{manifest_filepath}' does not exist"
  end

  LOGGER.info("Destination base: #{destination_base}")
  LOGGER.info("Manifest: #{manifest_filepath}")

  manifest = YAML.load(File.read(manifest_filepath))

  raise "Expected YAML mapping at root of document ('#{manifest_filepath}')" unless manifest.is_a?(Hash)

  manifest = Hash[
    manifest.map do |file, params|
      file = File.expand_path(file) + (file.end_with?(?/) ? ?/ : '')

      raise "'#{file}' does not exist" unless File.exist?(file)

      destination = params.fetch('destination')
      destination = File.join(destination_base, destination)

      mode = params.fetch('mode').to_sym

      raise "Unknown mode '#{mode}' (modes: #{MODES.join(', ')})" unless MODES.include?(mode)

      modify_window = params.fetch('modify-window', nil)

      raise 'Must specify timestamp --modify-window value as an integer' unless modify_window.nil? || modify_window.is_a?(Integer)

      [file, { destination: destination, mode: mode, modify_window: modify_window }]
    end
  ]

  exitstatus = nil

  manifest.each do |file, params|
    options =
      case params.fetch(:mode)
      when :synchronize
        %w[--archive --delete]
      when :clone
        %w[--archive]
      when :move
        %w[--archive --remove-source-files]
      end

    options = options.push('--modify-window', params.fetch(:modify_window).to_s) unless params.fetch(:modify_window).nil?

    options = options.push('--dry-run') if ENV['DRY_RUN']

    command = [
      'rsync',
      *options,
      '--partial',
      '--verbose',
      '--human-readable',
      '--itemize-changes',
      file,
      params.fetch(:destination)
    ]

    Open3.popen2e(*command) { |stdin, stdout_and_stderr, thread|
      LOGGER.info("rsync #{file} (mode: #{params.fetch(:mode)}, PID: #{thread.pid})")

      stdin.close
      stdout_and_stderr.each { |line| LOGGER.info(line.rstrip) }
      status = thread.value

      unless status.success?
        LOGGER.error("rsync #{file} failed")

        exitstatus ||= status.exitstatus
      end
    }
  end

  exit exitstatus || 0
end

main
