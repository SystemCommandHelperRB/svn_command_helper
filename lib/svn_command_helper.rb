require "svn_command_helper/version"
require 'pathname'
require 'yaml'
require 'time'
require 'tmpdir'
require 'ostruct'
require 'rexml/document'
require "system_command_helper"

# Subversion command helper
module SvnCommandHelper
  # Subversion native command and some utilities
  module Svn
    # module methods
    module ModuleMethods
      include ::SystemCommandHelper

      # svn commit
      # @param [String] message commit message
      # @param [path string like] path target path
      def commit(message, path = ".")
        if cap("svn status #{path}").empty?
          sys "svn revert -R #{path}"
          puts "[WARNING] no change: #{message}"
        else
          sys "svn commit -m '#{message}' #{path}"
        end
        sys "svn update #{path}"
      end

      # svn list
      # @param [uri string like] uri target uri
      # @param [Boolean] recursive --recursive
      # @return [Array<String>] paths
      def list(uri, recursive = false)
        cap("svn list #{recursive ? '-R' : ''} #{uri}").split(/\n/).compact
          .reject {|path| path.empty?}
      end

      # svn list --recursive
      # @param [uri string like] uri target uri
      # @return [Array<String>] paths
      def list_recursive(uri)
        list(uri, true)
      end

      # svn list -> grep only files
      # @param [uri string like] uri target uri
      # @param [Boolean] recursive --recursive
      # @return [Array<String>] file paths
      def list_files(uri, recursive = false)
        list(uri, recursive).reject {|path| path.end_with?("/")} # dir
      end

      # svn list --recursive -> grep only files
      # @param [uri string like] uri target uri
      # @return [Array<String>] file paths
      def list_files_recursive(uri)
        list_files(uri, true)
      end

      # check svn uri exists or not
      # @param [uri string like] uri target uri
      # @return [Boolean] true if exists
      def exist?(uri)
        basename = File.basename(uri)
        list(File.dirname(uri)).find{|_basename| File.fnmatch(basename, _basename.sub(/\/$/, ''))}
      end

      # check svn uri file exists or not
      # @param [uri string like] uri target uri
      # @return [Boolean] true if exists
      def exist_file?(uri)
        file = File.basename(uri)
        list_files(File.dirname(uri)).find{|_file| File.fnmatch(file, _file)}
      end

      # svn update
      # @param [path string like] path target path
      # @param [depth] depth --set-depth
      def update(path = ".", depth = nil)
        sys "svn update #{depth ? "--set-depth #{depth}" : ""} #{path}"
      end

      # svn log
      # @param [uri string like] uri target uri
      # @param [Integer] limit --limit
      # @param [Boolean] stop_on_copy --stop-on-copy
      # @return [Array<OpenStruct>] log (old to new order)
      def log(uri = ".", limit: nil, stop_on_copy: false)
        log = cap "svn log --xml #{limit ? "--limit #{limit}" : ""} #{stop_on_copy ? "--stop-on-copy" : ""} #{uri}"
        REXML::Document.new(log).elements.collect("/log/logentry") do |entry|
          OpenStruct.new({
            revision: entry.attribute("revision").value.to_i,
            author: entry.elements["author"].text,
            date: Time.iso8601(entry.elements["date"].text),
            msg: entry.elements["msg"].text,
          })
        end.reverse
      end

      # head revision of uri
      # @param [uri string like] uri target uri
      # return [Integer] revision number
      def revision(uri = ".")
        log(uri, limit: 1).last.revision
      end

      # stop-on-copy revision of uri
      # @param [uri string like] uri target uri
      # return [Integer] revision number
      def copied_revision(uri = ".")
        log(uri, stop_on_copy: true).first.revision
      end

      # svn update to deep path recursive
      # @param [path string like] path target path
      # @param [depth] depth --set-depth for only new updated dirs
      def update_deep(path, depth = nil)
        root = Pathname.new(Svn.working_copy_root_path(path)).realpath
        end_path = Pathname.new(path.to_s).expand_path.realpath
        parents = [end_path]
        while parents.first != root
          parents.unshift(parents.first.parent)
        end
        parents.each do |dir|
          if dir.exist?
            sys "svn update #{dir}"
          else
            sys "svn update #{depth ? "--set-depth #{depth}" : ""} #{dir}"
          end
        end
      end

      # svn info -> yaml parse
      # @param [path string like] path target path
      # @return [Hash<String, String>] svn info contents
      def info(path = ".")
        YAML.load(cap("svn info #{path}"))
      end

      # svn cat
      # @param [path string like] path target path
      # @return [String] file contents
      def cat(path)
        cap("svn cat #{path}")
      end

      # Working Copy Root Path from svn info
      # @param [path string like] path target path
      # @return [String] Working Copy Root Path
      def working_copy_root_path(path = ".")
        info(path)["Working Copy Root Path"]
      end

      # find common part of the given uris
      # @param [Array<uri string like>] uris target uri
      # @return [String] common part of the given uris
      def base_uri_of(uris)
        uris.reduce(Pathname.new(uris.first.to_s)) do |base_uri, uri|
          rel = Pathname.new(uri).relative_path_from(base_uri)
          to_parent = rel.to_s.match(/(?:\.\.\/)*/).to_s
          to_parent.empty? ? base_uri : base_uri + to_parent
        end.to_s
      end

      # copy single transaction
      # @param [SvnFileCopyTransaction] transaction from and to info
      # @param [String] message commit message
      def copy_single(transaction, message)
        transactions = transaction.glob_transactions
        raise "copy_single: #{transaction.from} not exists" if transactions.empty?
        to_exist_transactions = Svn.list_files(transaction.to_base).map do |_file|
          transactions.find {|_transaction| _transaction.file == _file}
        end.compact
        only_from_transactions = transactions - to_exist_transactions
        if to_exist_transactions.empty? # toにファイルがない
          sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} #{transaction.to_base} -m '#{message}'"
        else
          Dir.mktmpdir do |dir|
            Dir.chdir(dir) do
              sys "svn checkout --depth empty #{transaction.to_base} ."
              unless only_from_transactions.empty?
                sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} ."
              end
              to_exist_transactions.each do |_transaction|
                sys "svn update --set-depth infinity #{_transaction.file}"
                sys "svn merge --accept theirs-full #{_transaction.from} #{_transaction.file}"
              end
              Svn.commit(message, ".")
            end
          end
        end
      end

      # copy multi transactions
      # @param [Array<SvnFileCopyTransaction>] transactions from and to info list
      # @param [String] message commit message
      def copy_multi(transactions, message)
        base_uri = base_uri_of(transactions.map(&:from_base) + transactions.map(&:to_base))
        transactions.each do |transaction|
          raise "copy_multi: #{transaction.from} not exists" unless transaction.from_exist?
        end
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            sys "svn checkout --depth empty #{base_uri} ."
            transactions.each do |transaction|
              relative_to = transaction.relative_to(base_uri)
              Svn.update_deep(relative_to, "empty") # mkpath的な なくてもエラーにはならないので

              if transaction.to_exist?  # toがある場合マージ
                sys "svn merge --accept theirs-full #{transaction.from} #{relative_to}"
              else # toがない場合コピー
                sys "svn copy --parents #{transaction.from} #{relative_to}"
              end
            end
            Svn.commit(message, ".")
          end
        end
      end

      # check transaction from file exists
      # @param [SvnFileCopyTransaction] transaction from and to info
      # @param [Boolean] raise_if_from_not_found raise if from not found
      # @return [Boolean] true if file exists
      def check_exists(transaction, raise_if_from_not_found = true)
        unless transaction.from_exist?
          if !raise_if_from_not_found
            false
          elsif transaction.to_exist?
            puts "[WARNING] File:#{file}はコピー先のみにあります"
            false
          else
            raise "[Error] File:#{file}が見つかりません！"
          end
        else
          true
        end
      end
    end

    extend ModuleMethods
  end

  # svn file copy transaction
  # @attr [String] from_base from base uri
  # @attr [String] to_base to base uri
  # @attr [String] file file basename
  class SvnFileCopyTransaction
    attr_reader :from_base
    attr_reader :to_base
    attr_reader :file

    # @param [String] from_base from base uri
    # @param [String] to_base to base uri
    # @param [String] file file basename
    def initialize(from_base:, to_base:, file:)
      @from_base = from_base
      @to_base = to_base
      @file = file
    end

    # from uri
    # @return [String] from uri
    def from
      File.join(@from_base, @file)
    end

    # to uri
    # @return [String] to uri
    def to
      File.join(@to_base, @file)
    end

    # filename glob (like "hoge*") to each single file transaction
    # @return [Array<SvnFileCopyTransaction>] transactions
    def glob_transactions
      Svn.list_files(@from_base)
        .select{|_file| File.fnmatch(@file, _file)}
        .map{|_file| SvnFileCopyTransaction.new(from_base: @from_base, to_base: @to_base, file: _file)}
    end

    # from uri exists?
    # @return [Boolean]
    def from_exist?
      Svn.exist_file?(from)
    end

    # to uri exists?
    # @return [Boolean]
    def to_exist?
      Svn.exist_file?(to)
    end

    # relative from base path from given base uri
    # @return [String] relative from base path
    def relative_from_base(path)
      Pathname.new(@from_base).relative_path_from(Pathname.new(path)).to_s
    end

    # relative to base path from given base uri
    # @return [String] relative to base path
    def relative_to_base(path)
      Pathname.new(@to_base).relative_path_from(Pathname.new(path)).to_s
    end

    # relative from path from given base uri
    # @return [String] relative from path
    def relative_from(path)
      File.join(relative_from_base(path), @file)
    end

    # relative to path from given base uri
    # @return [String] relative to path
    def relative_to(path)
      File.join(relative_to_base(path), @file)
    end
  end
end
