# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2021 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::QMPlugin::Base;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Base

abstract base class for nodes, edges and roles

=cut

use strict;
use warnings;

use Foswiki::Plugins::QMPlugin();
use Foswiki::Func ();
use Foswiki::Plugins::MultiLingualPlugin ();
use Error qw(:try);

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0;    # toggle me

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of a class of its kind;
node, edge and role classes each refine this list 

=cut

use constant PROPS => qw();

=begin TML

---++ ClassMethod new() -> $core

constructor for a Base object

=cut

sub new {
  my $class = shift;
  my $net = shift;

  my $this = bless({@_}, $class);
  $this->{_net} = $net;

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  undef $this->{_net};
}

=begin TML

---++ ObjectMethod props() -> @props

returns a list of all known property keys of this class

=cut

sub props {
  my $this = shift;

  my $class = ref($this);

  my %props = ();
  $props{$_} = 1 foreach grep { !/^_/ } (keys %$this, $class->PROPS);

  #print STDERR "props of $this: ".join(", ", sort keys %props)."\n";

  return keys %props;
}

=begin TML

---++ ObjectMethod prop($key, $val) -> $val

getter/setter for a property of this class

=cut

sub prop {
  my ($this, $key, $val) = @_;

  return if $key =~ /^_/;

  if (defined $val) {
    $this->{$key} = $val;
  } else {
    $val = $this->{$key};
    $val = $this->{$key} = $this->_getPropLazy($key) unless defined $val;
  }

  return $val;
}

=begin TML

---++ ObjectMethod _getPropLazy($key) -> $val

get a property lazily. this method is called by prop() if the 
given property does not exist (yet). 

=cut

sub _getPropLazy {
  my ($this, $key) = @_;

  my $val;
  return $val;
}

=begin TML

---++ ObjectMethod expandValue($val) -> $val

expand the given value in the context of a state this object is in

=cut

sub expandValue {
  my ($this, $val) = @_;

  my $state = $this->getNet->getState;
  $val = $state->expandValue($val) if $state;

  return $val;
}

=begin TML

---++ ObjectMethod getNet() -> $net

get the net this object is part of 

=cut

sub getNet {
  my $this = shift;

  return $this->{_net};
}


=begin TML

---++ ObjectMethod getCore() -> $core

convenience method to get the plugin core

=cut

sub getCore {
  my $this = shift;

  return Foswiki::Plugins::QMPlugin->getCore();
}

=begin TML

---++ ObjectMethod index() -> $index

get the unique index of this object in a set of same objects part of a net 

=cut

sub index {
  my ($this, $val) = @_;

  $this->{_index} = $val if defined $val;

  return $this->{_index};
}

=begin TML

---++ ObjectMethod stringify() -> $string

returns a string representation of this object

=cut

sub stringify {
  my $this = shift;

  my @result = ();
  foreach my $key (sort $this->props) {
    push @result, "$key=" . ($this->prop($key) // 'undef');
  }

  return join(", ", @result);
}

=begin TML

---++ ObjectMethod getWebTopic() -> ($web, $topic, $rev)

returns the web, topic and revision of the current state in which this
object is; returns =('', '', '')= if the object has no state assigned to it

=cut

sub getWebTopic {
  my $this = shift;

  my $state = $this->getNet->getState;

  return ($state->getWeb(), $state->getTopic, $state->getRevision()) if $state;
  return ('', '', '');
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render the properties of this object given the specified format string;
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  return "" unless defined $format;

  my $result = $format;
  my $propRegex = join("|", $this->props);
  $params //= {};

  $result =~ s/\$($propRegex)\b/$this->_renderProp($params, $1)/ge;

  my ($web, $topic, $rev) = $this->getWebTopic();

  $result =~ s/\$web\b/$web/g;
  $result =~ s/\$topic\b/$topic/g;
  $result =~ s/\$rev\b/$rev/g;

  return $this->expandHelpers($result);
}

sub _renderProp {
  my ($this, $params, $key) = @_;

  my $val = $this->prop($key); 
  $val = $params->{$key} unless defined $val && $val ne ""; 
  $val = $this->expandValue($val); 
  
  return $key eq 'title' ? $this->translate($val) : $val 
}

=begin TML

---++ ObjectMethod expandHelpers($format) -> $string

expand helper functions during the render process 

=cut

sub expandHelpers {
  my ($this, $result) = @_;

  $result =~ s/\$formatTime\((\d+?)(?:, *(.*?))?\)/$this->_formatTime($1, $2)/ge;
  $result =~ s/\$formatDateTime\((\d+?)\)/$this->_formatTime($1, $Foswiki::cfg{DateManipPlugin}{DefaultDateTimeFormat} || $Foswiki::cfg{DefaultDateFormat}.' - $hour:$min')/ge;
  $result =~ s/\$(?:wikiUserName|wikiusername)(?:\((.*?)\))?/$this->_userinfo('link', $1)/ge;
  $result =~ s/\$(?:wikiName|wikiname)(?:\((.*?)\))?/$this->_userinfo('wikiName', $1)/ge;
  $result =~ s/\$(?:userName|username)(?:\((.*?)\))?/$this->_userinfo('userName', $1)/ge;
  $result =~ s/\$emails?(?:\((.*?)\))?/$this->_userinfo('email', $1)/ge;
  $result =~ s/\$(action|edge)Title\((.*?)\)/$this->_actionTitle($1)/ge;
  $result =~ s/\$nodeTitle\((.*?)\)/$this->_nodeTitle($1)/ge;

  return $result;
}

sub _formatTime {
  my ($this, $epoch, $format) = @_;

  return "" unless $epoch;

  my $result;
  try {
    $result = Foswiki::Func::formatTime($epoch, $format);
  } catch Error with {};

  $result ||= '';

  return $result;
}

sub _userinfo {
  my ($this, $type, $user) = @_;

  return "" unless $user;

  $type ||= 'wikiName';

  my @result = ();
  foreach my $id (split(/\s*,\s*/, $user)) {
    my $obj = $this->getCore->getUser($id) || $this->getCore->getGroup($id);
    unless (defined $obj) {
      print STDERR "WARNING: cannot find user or group for $id\n";
      next;
    }
    if ($type eq 'link') {
      push @result, $obj->getLink();
    } else {
      my $val = $obj->prop($type);
      if (defined $val) {
        push @result, $val;
      } else {
        print STDERR "WARNING: no property '$type' in user/group ".$obj->prop("id")."\n";
      }
    }
  }

  return join(", ", @result);
}

sub translate {
  my ($this, $string) = @_;

  my $web;
  my $topic;

  my $state = $this->getNet->getState();
  if ($state) {
    $web = $state->getWeb();
    $topic = $state->getTopic();
  }

  $string =~ s/^_+//; # strip leading underscore as maketext doesnt like it

  return Foswiki::Plugins::MultiLingualPlugin::translate($string, $web, $topic);
}

sub _nodeTitle {
  my ($this, $id) = @_;

  return "" unless defined $id;

  my $node = $this->getNet->getNode($id);
  return "" unless $node;

  return $this->translate($node->prop("title"));
}

sub _actionTitle {
  my ($this, $param) = @_;

  return "" unless defined $param;

  my ($from, $action, $to) = split(/\s*,\s*/, $param);
  my $edge = $this->getNet->getEdge($from, $action, $to);

  return "" unless $edge;

  return $this->translate($edge->prop("title"));
}

=begin TML

---++ ObjectMethod hasAccess($type, $user) -> $boolean

checks the type of access for the given user

=cut

sub hasAccess {
  my ($this, $type, $user) = @_;

  my $allowed = $this->expandValue($this->prop($type));
  return $this->_isInList($allowed, $user);
}

sub _isInList {
  my ($this, $list, $user) = @_;

  #print STDERR "called _isInList($list, $user)\n";;

  return 0 unless defined $list;

  $list =~ s/^\s+|\s+$//g;

  return 1 unless $list;
  return 1 if $list eq '*';
  return 0 if $list =~ /^nobody$/i;

  $user ||= $this->getCore->getSelf();
  #return 1 if Foswiki::Func::isAnAdmin($user);

  # get role members
  my @list = ();
  foreach my $id (split(/\s*,\s*/, $list)) {

    # role
    my $role = $this->getNet->getRole($id);
    if ($role) {
      push @list, $role->getMembers();
      next;
    } 

    # user
    my $user = $this->getCore->getUser($id);
    if (defined $user) {
      push @list, $user;
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if (defined $group) {
      push @list, $group;
      next;
    }
  }

  # check acl
  foreach my $obj (@list) {
    return 1 if $obj->prop("id") eq $user->prop("id");
    return 1 if $obj->can("hasMember") && $obj->hasMember($user);
  }

  return 0;
}

=begin TML

---++ ObjectMethod writeDebug($string)

prints the given string to STDERR when TRACE is enabled

=cut

sub writeDebug {
  my ($this, $msg) = @_;

  return unless TRACE;
  print STDERR ref($this) . " - $msg\n";
}

1
