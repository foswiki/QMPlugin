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

package Foswiki::Plugins::QMPlugin::Node;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Node

implements a Node in a workflow Net

Nodes in a net are connected by Edges

=cut

use strict;
use warnings;

use Foswiki::Plugins::QMPlugin::Base();
our @ISA = qw( Foswiki::Plugins::QMPlugin::Base );

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of a node

=cut

use constant PROPS => qw(
  allowEdit 
  allowView
  class
  id 
  message 
  title 
);

=begin TML

---++ ClassMethod new() -> $core

constructor for a node object

=cut

sub new {
  my $class = shift;

  my $this = $class->SUPER::new(@_);
  $this->{title} //= $this->{id};

  $this->index($this->getNet()->{_nodeCounter}++);

  $this->{_incomingEdges} = [];
  $this->{_outgoingEdges} = [];

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  $this->SUPER::finish();

  undef $this->{_incomingEdges};
  undef $this->{_outgoingEdges};
}

=begin TML

---++ ObjectMethod addIncomingEdge($edge)

register an incoming edge for this node

=cut

sub addIncomingEdge {
  my ($this, $edge) = @_;

  push @{$this->{_incomingEdges}}, $edge;
}

=begin TML

---++ ObjectMethod addOutgoingEdge($edge)

register an outgoing edge from this node

=cut

sub addOutgoingEdge {
  my ($this, $edge) = @_;

  push @{$this->{_outgoingEdges}}, $edge;
}

=begin TML

---++ ObjectMethod getOutgoingEdges() -> @edges

get the list of outgoing edges from this node

=cut

sub getOutgoingEdges {
  my $this = shift;

  return @{$this->{_outgoingEdges}};
}

=begin TML

---++ ObjectMethod getIncomingEdges() -> @edges

get the list of incoming edges to this node

=cut

sub getIncomingEdges {
  my $this = shift;

  return @{$this->{_incomingEdges}};
}

=begin TML

---++ ObjectMethod getNextNodes() -> @nodes

get the list of nodes of outging edges from this node

=cut

sub getNextNodes {
  my $this = shift;

  my @nodes = ();
  push @nodes, $_->toNode foreach $this->getOutgoingEdges();

  return @nodes;
}

=begin TML

---++ ObjectMethod getPreviousNodes() -> @nodes

get the list of nodes of incoming edges to this node

=cut

sub getPreviousNodes {
  my $this = shift;

  my @nodes = ();
  push @nodes, $_->toNode foreach $this->getIncomingEdges();

  return @nodes;
}

=begin TML

---++ ObjectMethod getACL($type) -> @list

get the access control list to control the given type of action

=cut

sub getACL {
  my ($this, $type) = @_;

  my $list = $this->expandValue($this->prop($type));
  $list =~ s/^\s+|\s+$//g;

  my %list = ();

  foreach my $id (split(/\s*,\s*/, $list)) {
    next if $id =~ /^(nobody)$/i;

    # role
    my $role = $this->getNet->getRole($id);
    if ($role) {
      my @members = $role->getMembers(0);
      $list{$_->prop("wikiName") || $_->prop("id")} = $_ foreach $role->getMembers(0);
      next;
    } 

    # user
    my $user = $this->getCore->getUser($id);
    if ($user) {
      $list{$user->prop("wikiName")} = $user;
      next;
    }

    # group
    my $group = $this->getCore->getGroup($id);
    if ($group) {
      $list{$group->prop("wikiName")} = 1;
      next;
    }

    print STDERR "WARNING: undefined type of member '$id' (not a role, user or group)\n"
  }

  my @result = sort keys %list;  
  return @result;
}

=begin TML

---++ ObjectMethod hasViewAccess($user) -> $boolean

returns true when the given user has got view access to this node

=cut

sub hasViewAccess {
  my $this = shift;
  return $this->hasAccess("allowView", @_);
}

=begin TML

---++ ObjectMethod hasEditAccess($user) -> $boolean

returns true when the given user has got edit access to this node

=cut

sub hasEditAccess {
  my $this = shift;
  return $this->hasAccess("allowEdit", @_);
}

=begin TML

---++ ObjectMethod render($format, $params) -> $string

render this node given the specified format string
params is a hash reference with default values for properties not defined

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $result = $this->SUPER::render($format, $params);
  $result =~ s/\$state\b/$this->prop("id")/ge; # alias

  return $result;
};

1;
