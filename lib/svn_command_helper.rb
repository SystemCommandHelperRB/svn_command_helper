require "svn_command_helper/version"
require 'pathname'
require 'yaml'
require "system_command_helper"

module SvnCommandHelper
  module Svn
    module ModuleMethods
      include ::SystemCommandHelper

      def commit(message, path = ".")
        if cap("svn status #{path}").empty?
          sys "svn revert -R #{path}"
          puts "[WARNING] no change: #{message}"
        else
          sys "svn commit -m '#{message}' #{path}"
        end
        sys "svn update #{path}"
      end

      def list(uri, recursive = false)
        cap("svn list #{recursive ? '-R' : ''} #{uri}").split(/\n/).compact
          .reject {|path| path.empty?}
      end

      def list_recursive(uri)
        list(uri, true)
      end

      def list_files(uri, recursive = false)
        list(uri, recursive).reject {|path| path.end_with?("/")} # dir
      end

      def list_files_recursive(uri)
        list_files(uri, true)
      end

      def update(path, depth = nil)
        sys "svn update #{depth ? "--set-depth #{depth}" : ""} #{path}"
      end

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

      def info(path = ".")
        YAML.load(cap("svn info #{path}"))
      end

      def cat(path)
        cap("svn cat #{path}")
      end

      def working_copy_root_path(path = ".")
        info(path)["Working Copy Root Path"]
      end

      def base_uri_of(uris)
        uris.reduce(Pathname.new(uris.first.to_s)) do |base_uri, uri|
          rel = Pathname.new(uri).relative_path_from(base_uri)
          to_parent = rel.to_s.match(/(?:\.\.\/)*/).to_s
          to_parent.empty? ? base_uri : base_uri + to_parent
        end.to_s
      end

      def copy_single(transaction, message)
        transactions = transaction.glob_transactions
        raise "copy_single: #{transaction.from} not exists" if transactions.empty?
        to_exist_transactions = Svn.list_files(transaction.to_base).select do |_file|
          transactions.find {|_transaction| _transaction.file == _file}
        end.compact
        only_from_transactions = transactions - to_exist_transactions
        if to_exist_transactions.empty? # toにファイルがない
          sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} #{transaction.to_base} -m '#{message}'"
        else
          Dir.mktmpdir do |dir|
            sys "svn checkout --depth empty #{transaction.to_base} ."
            sys "svn copy --parents #{only_from_transactions.map(&:from).join(' ')} ."
            to_exist_transactions.each do |_transaction|
              sys "svn update --set-depth infinity #{_transaction.file}"
              sys "svn merge --accept theirs-full #{_transaction.from} #{_transaction.file}"
            end
            Svn.commit(message, ".")
          end
        end
      end

      def copy_multi(transactions, message)
        base_uri = base_uri_of(transactions.map(&:from_base) + trnsactions.map(&:to_base))
        transactions.each do |transaction|
          raise "copy_multi: #{transaction.from} not exists" unless transaction.from_exist?
        end
        Dir.tmpdir do |dir|
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

      def check_exists(transaction, raise_if_from_not_found = true)
        unless transaction.from_exist?
          if !raise_if_from_not_found
            return
          elsif transaction.to_exist?
            puts "[WARNING] File:#{file}はコピー先のみにあります"
            return
          else
            raise "[Error] File:#{file}が見つかりません！"
          end
        end
      end
    end

    extend ModuleMethods
  end

  class SvnFileCopyTransaction
    attr_reader :from_base, :to_base, :file

    def initialize(from_base:, to_base:, file:)
      @from_base = from_base
      @to_base = to_base
      @file = file
    end

    def from
      File.join(@from_base, @file)
    end

    def to
      File.join(@to_base, @file)
    end

    def glob_transactions
      Svn.list_files(@from_base)
        .select{|_file| File.fnmatch(@file, _file)}
        .map{|_file| SvnFileCopyTransaction.new(from_base: @from_base, to_base: @to_base, file: _file)}
    end

    def from_exist?
      Svn.list_files(@from_base).find{|_file| File.fnmatch(@file, _file)}
    end

    def to_exist?
      Svn.list_files(@to_base).find{|_file| File.fnmatch(@file, _file)}
    end

    def relative_from_base(path)
      Pathname.new(@from_base).relative_path_from(Pathname.new(path)).to_s
    end

    def relative_to_base(path)
      Pathname.new(@to_base).relative_path_from(Pathname.new(path)).to_s
    end

    def relative_from(path)
      File.join(relative_from_base(path), @file)
    end

    def relative_to(path)
      File.join(relative_from_to(path), @file)
    end
  end
end
