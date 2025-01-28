# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2023-2025 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::QMPlugin::TopicIterator;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::QMIterator

iterate over topics with a qmstate

=cut

use strict;
use warnings;

use constant TRACE => 0;

use constant MODE_DEFAULT => 0;
use constant MODE_SOLR => 1;
use constant MODE_DBCACHE => 2;

# for testing
use constant ENABLED_SOLR => 1;
use constant ENABLED_DBCACHE => 1;

use Foswiki::Func ();
use Foswiki::Iterator ();
our @ISA = ('Foswiki::Iterator');


sub new {
  my $class = shift;


  my $this = bless({
    @_
  }, $class);

  my $context = Foswiki::Func::getContext();
  if (ENABLED_SOLR && $context->{SolrPluginEnabled}) {
    $this->{_mode} = MODE_SOLR;
    require Foswiki::Plugins::SolrPlugin;
  } elsif (ENABLED_DBCACHE && $context->{DBCachePluginEnabled}) {
    $this->{_mode} = MODE_DBCACHE;
    require Foswiki::Plugins::DBCachePlugin;
  } else {
    $this->{_mode} = MODE_DEFAULT;
  }

  $this->reset();

  return $this;
}

sub DESTROY {
  my $this = shift;

  undef $this->{_matches};
  undef $this->{webs};
}

sub hasNext {
  my $this = shift;

  my $matches = $this->matches;
  return 0 unless defined $matches;

  if ($this->{_mode} eq MODE_SOLR) {
    return (scalar(@$matches) || $this->{_numFound} > $this->{_start}) ? 1:0;
  }

  return $matches->hasNext || $this->{_webIndex} < scalar(@{$this->{webs}});;
}

sub next {
  my $this = shift;

  my $matches = $this->matches;
  return unless defined $matches;

  if ($this->{_mode} eq MODE_SOLR) {
    my $doc = pop(@$matches);
    unless (defined $doc) {
      undef $this->{_matches};
      return $this->next;
    }
    my $web =  $doc->value_for("web");
    my $topic = $doc->value_for("topic");
    return ($web, $topic);
  }

  unless ($matches->hasNext) {
    undef $this->{_matches};
    return $this->next;
  }

  if ($this->{_mode} eq MODE_DBCACHE) {
    my $obj = $matches->next;
    return ($obj->fastget("web"), $obj->fastget("topic"));
  }

  #default
  my ($web, $topic) = Foswiki::Func::normalizeWebTopicName(undef, $matches->next); # outch
  return ($web, $topic);
}

sub reset { 
  my $this = shift;

  $this->{_webIndex} = 0;
  $this->{_start} = 0;
  undef $this->{_matches};
  undef $this->{_numFound};

  if ($this->{_mode} ne ENABLED_SOLR && (!$this->{webs} || !scalar(@{$this->{webs}}))) {

    my @webs = Foswiki::Func::getListOfWebs( "user,public" );

    if ($this->{includeWeb}) {
      my $include = $this->{includeWeb};
      $include =~ s/,/|/g;
      @webs = grep {/$include/} @webs;
    }

    if ($this->{excludeWeb}) {
      my $excludeWeb = $this->{excludeWeb};
      $excludeWeb =~ s/,/|/g;
      @webs = grep {!/$excludeWeb/} @webs;
    }
    $this->{webs} = \@webs;
  }

  return $this->matches();
}

sub matches {
  my $this = shift;

  return $this->{_matches} if defined $this->{_matches};


  if ($this->{_mode} eq MODE_DBCACHE) {
    my $web = $this->web;
    return unless $web;

    my $db = Foswiki::Plugins::DBCachePlugin::getDB($web);
    return unless $db;
    $this->{_matches} = $db->dbQuery("qmstate", undef, "topic");
    $this->{_webIndex}++;
    return $this->{_matches};
  } 

  if ($this->{_mode} eq MODE_SOLR) {
    my $searcher = Foswiki::Plugins::SolrPlugin::getSearcher();

    my $query = "field_QMStateID_s:* type:topic ";

    $query .= "web:(".join(" OR ", @{$this->{webs}}).") " if defined $this->{webs} && scalar(@{$this->{webs}});
    $query .= "web_search:(".join(" OR ", split(/\s*,\s*/, $this->{includeWeb})).") " if $this->{includeWeb};
    $query .= "-web_search:(".join(" OR ", split(/\s*,\s*/, $this->{excludeWeb})).") " if $this->{excludeWeb};

    print STDERR "query=$query\n" if TRACE;

    my $response = $searcher->solrSearch($query, {
      fl => "web, topic",
      rows => $this->{rows} // 1000,
      sort => "topic_sort asc",
      start => $this->{_start},
    });

    my @docs = $response->docs;
    $this->{_matches} = \@docs;
    my $len = scalar(@docs);
    $this->{_numFound} = $response->content->{response}->{numFound};

    print STDERR "start=$this->{_start}, numFound=$this->{_numFound}\n" if TRACE;

    $this->{_start} += $len;

    return $this->{_matches};
  } 

  # default
  my $web = $this->web;
  return unless $web;

  $this->{_matches} = Foswiki::Func::query("qmstate", undef, { 
    type => "query",
    web => $web,
    files_without_match => 1 
  });
  $this->{_webIndex}++;
  return $this->{_matches};
}

sub web {
  my $this = shift;

  return unless defined $this->{webs};
  return if $this->{_webIndex} > scalar(@{$this->{webs}});

  my $web = $this->{webs}[$this->{_webIndex}];
  #if ($this->{_mode} eq MODE_DBCACHE) {
  #  Foswiki::Plugins::DBCachePlugin::getCore()->currentWeb($web);
  #}

  return $web;
}

1;
