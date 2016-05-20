require 'spec_helper'

include SvnCommandHelper

describe SvnCommandHelper do
  it 'has a version number' do
    expect(SvnCommandHelper::VERSION).not_to be nil
  end

  # TODO: fails if svn command does not exists
  it 'does something useful' do
    base_uri = Svn.base_uri_of([
      "svn+ssh://example.com/trunk/ghost/ikaga/ghost/master",
      "svn+ssh://example.com/trunk/ghost/zunko/shell",
      "svn+ssh://example.com/trunk/ghost/zunko/shell/master",
    ])
    expect(base_uri).to eq("svn+ssh://example.com/trunk/ghost")
  end
end
