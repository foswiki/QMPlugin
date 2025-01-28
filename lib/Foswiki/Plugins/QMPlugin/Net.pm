# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2025 Michael Daum http://michaeldaumconsulting.com
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

package Foswiki::Plugins::QMPlugin::Net;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Net

implements a workflow network

A net consists of nodes, edges that connect them and 
roles that participate in this workflow. A net is constructed
on the base of a workflow definition. A net can either be
defined in a way only reflecting the typology or have a State
assigned to it. The State encodes the location within the network.
The state has been reached by having traversed the edges in the net from
the start node following outgoing directed edges.

=cut

use warnings;
use strict;

use Foswiki::Func ();
use Foswiki::Plugins::QMPlugin::Node ();
use Foswiki::Plugins::QMPlugin::Edge ();
use Foswiki::Plugins::QMPlugin::Role ();

#use Data::Dump qw(dump); 

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0;    # toggle me

=begin TML

---++ ClassMethod new($web, $topic, $state) -> $net

constructor for a net object; this either returns a net object
or undef when parsing of the network definition failed for some reason

=cut

sub new {
  my $class = shift;
  my $web = shift;
  my $topic = shift;
  my $state = shift;

  my $this = bless({@_}, $class);

  $this->{_adminRole} = undef;
  $this->{_approvalNodes} = undef;
  $this->{_defaultNode} = undef;
  $this->{_edgeCounter} = 0;
  $this->{_edges} = undef;
  $this->{_memberCounter} = 0;
  $this->{_nodeCounter} = 0;
  $this->{_nodes} = undef;
  $this->{_roleCounter} = 0;
  $this->{_state} = $state;
  $this->{_topic} = $topic;
  $this->{_web} = $web;

  return unless $this->parseTableDefinition;
  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed, calls finish() on its parts

=cut

sub finish {
  my $this = shift;

  _writeDebug("finishing net $this");

  foreach my $node ($this->getNodes) {
    $node->finish;
  }

  foreach my $edge ($this->getEdges) {
    $edge->finish;
  }

  undef $this->{_adminRole};
  undef $this->{_approvalNodes};
  undef $this->{_defaultNode};
  undef $this->{_edges};
  undef $this->{_meta};
  undef $this->{_nodes};
  undef $this->{_roles};
  undef $this->{_state};
  undef $this->{_topic};
  undef $this->{_web};
}

=begin TML

---++ ObjectMethod setState($state) -> $state

assign a state to this network

=cut

sub setState {
  my ($this, $state) = @_;

  return $this->{_state} = $state if defined $state;
}

=begin TML

---++ ObjectMethod getState() -> $state

get the state assigned to this network

=cut

sub getState {
  my $this = shift;

  return $this->{_state};
}

=begin TML

---++ ObjectMethod getNodes() -> @nodes

get the list of all nodes in this net

=cut

sub getNodes {
  my $this = shift;

  return () unless defined $this->{_nodes};
  return values %{$this->{_nodes}};
}

=begin TML

---++ ObjectMethod getNode($id) -> $node

get a node of a specific id

=cut

sub getNode {
  my ($this, $id) = @_;

  return unless defined $id;
  return $this->{_nodes}{$id};
}

=begin TML

---++ ObjectMethod getRoles() -> @roles

get the list of all roles in this net

=cut

sub getRoles {
  my $this = shift;

  return () unless defined $this->{_roles};
  return values %{$this->{_roles}};
}

=begin TML

---++ ObjectMethod getRole($id) -> $role

get a role of a specific id

=cut

sub getRole {
  my ($this, $id) = @_;

  return unless $id;
  return $this->{_roles}{$id};
}

=begin TML

---++ ObjectMethod getEdges() -> @edges

get the list of all edges in this net

=cut

sub getEdges {
  my $this = shift;

  return () unless defined $this->{_edges};
  return @{$this->{_edges}};
}

=begin TML

---++ ObjectMethod getEdge($from, $action, $to) -> $edge

get a specific edge in this net. The parameters =$from=, =$action= and
=$to= specify which edge to return. All parameters are optional and may
be specified in different combinations. If more than one edge matches
the given parameter will only the first one found be returned.

=cut

sub getEdge {
  my ($this, $from, $action, $to) = @_;

  my $fromId = ref($from)?$from->prop("id"):$from;
  my $toId = ref($to)?$to->prop("id"):$to;

  foreach my $edge ($this->getEdges) {
    return $edge if (!$fromId || $edge->prop("from") eq $fromId) &&
                    (!$action || $edge->prop("action") eq $action) &&
                    (!$toId || $edge->prop("to") eq $toId);
  }

  return;
}

=begin TML

---++ ObjectMethod getSortedItems($type, $propName) -> @items

get the list of all items of type =$type= (nodes, roles, edges)
sorted by the given property Name

=cut

sub getSortedItems {
  my ($this, $type, $propName) = @_;

  $type //= 'nodes';
  $propName //= 'index';

  my @items;

  if ($type eq "nodes") {
    @items = grep { $_->prop("id") ne '_unknown_' } $this->getNodes();
  } elsif ($type eq "edges") {
    @items = grep { $_->fromNode && $_->fromNode->prop("id") ne '_unknown_' }$this->getEdges();
  } else {
    @items = $this->getRoles();
  }


  # natural order
  return (sort { $a->{_index} <=> $b->{_index} } @items)
    if $propName eq 'off';

  # sort by index
  return (sort { $a->index <=> $b->index } @items)
    if $propName eq 'index' || $propName eq 'on';

  # sort by property
  my %sorting = ();
  my $isNumerical = 1;
  foreach my $item (@items) {
    my $key = $item->prop("id");
    my $val = $item->renderProp($propName);
    $isNumerical = 0 unless $val =~ /^[+-]?\d+(\.\d+)?$/;
    $sorting{$key} = $val;
  }

  return $isNumerical
    ? (sort { $sorting{$a->prop("id")} <=> $sorting{$b->prop("id")} } @items)
    : (sort { $sorting{$a->prop("id")} cmp $sorting{$b->prop("id")} } @items);
}

=begin TML

---++ ObjectMethod getSortedRoles($propName) -> @roles

get the list of all roles sorted a given property name

=cut

sub getSortedRoles {
  my $this = shift;

  return $this->getSortedItems("roles", @_);
}

=begin TML

---++ ObjectMethod getSortedNodes($propName) -> @nodes

get the list of all nodes sorted by a given property name

=cut

sub getSortedNodes {
  my $this = shift;

  return $this->getSortedItems("nodes", @_);
}

=begin TML

---++ ObjectMethod getSortedEdges($propName) -> @edges

get the list of all edges sorted by a given property name

=cut

sub getSortedEdges {
  my $this = shift;

  return $this->getSortedItems("edges", @_);
}

=begin TML

---++ ObjectMethod getDefinition() -> $webtopic

get the webtopic path of the network definition

=cut

sub getDefinition {
  my $this = shift;

  return $this->{_web}.'.'.$this->{_topic} if defined $this->{_web} && defined $this->{_topic};
}

=begin TML

---++ ObjectMethod getMeta() -> $meta

get the Foswiki::Meta object of the current net

SMELL: every qmstate should also record the revision of the workflow it is using

=cut

sub getMeta {
  my $this = shift;

  unless (defined $this->{_meta}) {
    my ($meta) = Foswiki::Func::readTopic($this->{_web}, $this->{_topic});
    $this->{_meta} = $meta;
  }
  
  return $this->{_meta};
}

=begin TML

---++ ObjectMethod getNotificationTemplate() -> $templateName

get the name of the template for workflow notification emails

=cut

sub getNotificationTemplate {
  my $this = shift;

  my $field = $this->getMeta->get('FIELD', 'NotificationTemplate');

  if ($field) {
    if ($field->{value}) {
      my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($this->{_web}, $field->{value});
      $field = "$web.$topic";
    } else {
      $field = "";
    }
  }

  $field ||= "qmpluginnotify";

  return $field;
}

=begin TML

---++ ObjectMethod getReminderTemplate() -> $string

get the name of the template for workflow reminders

=cut

sub getReminderTemplate {
  my $this = shift;

  my $field = $this->getMeta->get('FIELD', 'ReminderTemplate');
  $field = $field->{value} if $field;
  $field ||= "qmpluginreminder";

  return $field;
}


=begin TML

---++ ObjectMethod parseTableDefinition() -> $boolean

parse the definition for this net stored in TML tables. this is called by the constructor right away;
returns true when parsing was successfull. There is a certain amount of compatibility
with WorkflowPlugin in that workflow definitions written for it may be used in QMPlugin
as well.

---+++ WorkflowPlugin format
---++++ States
| *State* | *Allow Edit* | *Allow View* | *Message* |

---++++ Transitions
| *State*  | *Action* | *Next State* | *Allowed* | *Form* | *Notify *|


---+++ QMPlugin format
---++++ Roles table
| *ID* | *Members* | *Notify* |

---++++ Nodes table
| *ID* | *Title* | *Allow Edit* | *Allow View* | *Allow Approve* | *Message* |

---++++ Edges table
| *From*  | *Action* | *To* | *Allowed* | *Enabled* | *Notify* | *Command* | *Sign Off* |

=cut

sub parseTableDefinition {
  my $this = shift;

  return 1 if defined $this->{_nodes};

  _writeDebug("parseTableDefinition($this->{_web}, $this->{_topic})");

  $this->{_nodes} = {};
  $this->{_edges} = [];
  $this->{_roles} = {};

  unless (Foswiki::Func::topicExists($this->{_web}, $this->{_topic})) {
    _writeDebug("no net defined at web='$this->{_web}', topic='$this->{_topic}'");
    return 0;
  }

  my $meta = $this->getMeta();
  return 0 unless defined $meta;

  # adopted from WorkflowPlugin
  my $inTable;
  my @fields;

  foreach my $line (split(/\n/, $meta->text)) {
    if ($line =~ /^\s*\|\s*\*ID\*\s*\|\s*\*Members\*\s*\|/) {

      $inTable = 'ROLE';
      @fields = map { my $tmp = $_; $tmp =~ s/^\s+|\s+$|\*//g; $tmp } split(/\|/, $line);

      #_writeDebug("$inTable - fields='".join("','", @fields)."'");

    } elsif ($line =~ /^\s*\|\s*\*(From|State)\*\s*(\|.*)?\|\s*\*To\*\s*\|/ ||
        $line =~ /^\s*\|\s*\*State\*\s*\|\s*\*Action\*\s*\|\s*\*Next State\*\s*\|/) { # compatibility 

      $inTable = 'EDGE';
      @fields = map { my $tmp = $_; $tmp =~ s/^\s+|\s+$|\*//g; $tmp } split(/\|/, $line);

      #_writeDebug("$inTable - fields='".join("','", @fields)."'");

    } elsif ($line =~ /^\s*\|\s*\*ID\*\s*\|(\s*\*Title\*\s*\|(?:\s*\*Allow\s*View\*\s*\|)?\s*\*Allow\s*Edit\*\s*\|)?/ || 
             $line =~ /^\s*\|\s*\*State\*\s*\|(?:\s*\*Allow\s*View\*\s*\|)?\s*\*Allow\s*Edit\*\s*\|/) { # compatibility 

      $inTable = 'NODE';
      @fields = map { my $tmp = $_; $tmp =~ s/^\s+|\s+$|\*//g; $tmp } split(/\|/, $line);

      #_writeDebug("$inTable - fields='".join("','", @fields)."'");

    } elsif ($inTable && $line =~ /^\s*\|\s*\*([^\|]*?)\*.*\s*\|\s*$/) {
      # ignore comments
       _writeDebug("comment: $1");
    } elsif ($inTable && $line =~ /^\s*\|\s*.*\s*\|\s*$/) {

      my %data;
      my $i = 0;

      #_writeDebug("$inTable - line=$line");

      foreach my $fieldVal (split(/\|/, $line)) {
        if ($fields[$i]) {
          $fieldVal =~ s/^\s+|\s+$//g;

          my $fieldName = lcfirst($fields[$i]);
          $fieldName =~ s/[^\w.]//g;
          $fieldName = "id" if $fieldName eq 'iD';

          # map WorkflowPlugin fields to QMPlugin fields
          $fieldName = "id" if $inTable eq 'NODE' && $fieldName eq 'state' ;
          $fieldName = "from" if $inTable eq 'EDGE' && $fieldName eq 'state' ;
          $fieldName = "to" if $fieldName eq 'nextState';

          #_writeDebug("$inTable - i=$i, field=$fieldName, value='$fieldVal'");
          $data{$fieldName} = $fieldVal;
        }
        $i++
      }
      #_writeDebug("$inTable - data=".dump(\%data));
      $this->buildRole(\%data) if $inTable eq 'ROLE';
      $this->buildEdge(\%data) if $inTable eq 'EDGE';
      $this->buildNode(\%data) if $inTable eq 'NODE';

    } else {
      undef $inTable;
    }
  }

  unless (keys %{$this->{_nodes}}) {
    #print STDERR "No nodes in net at $this->{_web}.$this->{_topic}\n";
    return 0;
  }

  unless (scalar(@{$this->{_edges}})) {
    #print STDERR "No edges in net at $this->{_web}.$this->{_topic}\n";
    return 0;
  }

  # create unknown node
  my $unknownNode = $this->{_nodes}{_unknown_} = Foswiki::Plugins::QMPlugin::Node->new($this, 
    id => '_unknown_',
    title => '%TRANSLATE{"Unknown"}%',
    allowEdit => '',
    allowView => '',
    message => 'unknown node',
  );

  # create edge from unknown node to default node
  $this->buildEdge({
    from => '_unknown_',
    action => 'restart',
    title => '%TRANSLATE{"Restart workflow"}%',
    to => $this->getDefaultNode->prop("id"),
  });

  # set approvalNodes
  unless (defined $this->{_approvalNodes}) {
    my @list = ();
    foreach my $node ($this->getNodes) {
      push @list, $node if $node->isApprovalNode;
    }
    push @list, $unknownNode unless @list;
    $this->{_approvalNodes} = \@list;
  }

  # gather incoming and outgoing edges of nodes
  foreach my $edge ($this->getEdges) {
    my $fromNode = $edge->fromNode();
    unless (defined $fromNode) {
      print STDERR "ERROR: illegal edge: can't find node from=$edge->{from} in workflow $this->{_web}.$this->{_topic}, edge=".$edge->stringify."\n";
      next;
    }

    my $toNode = $edge->toNode();
    unless (defined $toNode) {
      print STDERR "ERROR: illegal edge: can't find node to=$edge->{to} in workflow $this->{_web}.$this->{_topic}, edge=".$edge->stringify."\n";
      next;
    }

    $toNode->addIncomingEdge($edge);
    $fromNode->addOutgoingEdge($edge);
  }

  return 1;
}

sub buildRole {
  my ($this, $data) = @_;

  my $adminID = $this->{_adminID} // Foswiki::Func::getPreferencesValue("QMPLUGIN_ADMIN") || 'Admin';
  my $isAdmin = $data->{id} =~ s/\*$// || $data->{id} eq $adminID;

  my $role = Foswiki::Plugins::QMPlugin::Role->new($this, %$data);
  $this->{_roles}{$role->prop("id")} = $role;

  if ($isAdmin) {
    if (defined $this->{_adminRole}) {
      print STDERR "WARNING: multiple admin roles in workflow $this->{_web}.$this->{_topic}\n";
    } else {
      $this->{_adminRole} = $role;
    }
  }

  return $role;
}

sub buildNode {
  my ($this, $data) = @_;

  #print STDERR "buildNode data=".dump($data)."\n";

  my $node = Foswiki::Plugins::QMPlugin::Node->new($this, %$data);
  $this->{_nodes}{$node->prop("id")} = $node;
  $this->{_defaultNode} //= $node;

  return $node;
}

sub buildEdge {
  my ($this, $data) = @_;

  if ($data->{from} eq '*') {
    my @edges = ();
    foreach my $node ($this->getSortedNodes()) {
      next if $data->{to} eq $node->prop("id"); # no circular edges
      my %newData = %$data;
      $newData{from} = $node->prop("id");
      push @edges, $this->buildEdge(\%newData);
    }
    return @edges;
  }

  if ($data->{to} eq '*') {
    my @edges = ();
    foreach my $node ($this->getSortedNodes()) {
      next if $data->{from} eq $node->prop("id"); # no circular edges
      my %newData = %$data;
      $newData{to} = $node->prop("id");
      push @edges, $this->buildEdge(\%newData);
    }
    return @edges;
  }

  $data->{action} //= $data->{to};
  $data->{title} = $data->{action} if !defined($data->{title}) || $data->{title} =~ /^\s*$/;

  my $edge = $this->getEdge($data->{from}, $data->{action}, $data->{to});
  _writeDebug("called buildEdge from=$data->{from}, action=$data->{action}, to=$data->{to}");

  if ($edge) {
    # merge
    _writeDebug("... merging to existing edge");
    foreach my $key ($edge->props()) {
      $edge->prop($key, $data->{$key}) if defined $data->{$key};
    }
  } else {
    $edge = Foswiki::Plugins::QMPlugin::Edge->new($this, %$data);
    push @{$this->{_edges}}, $edge;
  }

  return wantarray ? ($edge) : $edge;
}

=begin TML

---++ ObjectMethod getUnknownNode() -> $node

get the "unknown" node; it is a system node not part of the net

=cut

sub getUnknownNode {
  my $this = shift;

  return $this->getNode('_unknown_');
}

=begin TML

---++ ObjectMethod getDefaultNode() -> $node

get the default node; this is the first node in the node definition list

=cut

sub getDefaultNode {
  my $this = shift;

  return $this->{_defaultNode};
}

=begin TML

---++ ObjectMethod getApprovalNodes() -> $list

get all nodes marked as approval nodes in this net; this is the one node that has got an asterisk (*) assigned to it or
has got the ID QMPLUGIN_APPROVAL (defaults to approved)

=cut

sub getApprovalNodes {
  my $this = shift;

  return $this->{_approvalNodes} // [];
}

=begin TML

---++ ObjectMethod getAdminRole() -> $role

get the admin role of this net; this is the one role that has got an asterisk (*) assigned to it, or 
has got the ID QMPLUGIN_ADMIN (defaults to Admin)

=cut

sub getAdminRole {
  my $this = shift;

  return $this->{_adminRole};
}

=begin TML

---++ ObjectMethod isAdmin($user) 

returns true if the given user is member of the admin role

=cut

sub isAdmin {
  my ($this, $user) = @_;

  my $admins = $this->getAdminRole();
  return unless $admins;
  return $admins->isMember($user);
}

=begin TML

---++ ObjectMethod stringify() -> $string

returns a string representation of this object

=cut

sub stringify {
  my ($this) = @_;

  _writeDebug("stringify($this)");

  my $result = "";
  if ($this->{_roles}) {
    my @roles = $this->getSortedRoles();

    # generate header row
    $result .= "\n---++ Roles\n| *ID* | *Members* ";
    foreach my $key (sort $roles[0]->props) {
      $result .= "| *" . ucfirst($key) . "* " unless $key =~ /^(id|members)$/;
    }
    $result .= "|\n";

    # generate data rows
    foreach my $role (@roles) {
      $result .= "| $role->{id} ";
      my $val = $role->expandValue($role->prop("members"));
      $result .= "| $val ";
      foreach my $key (sort $role->props) {
        next if $key =~ /^(id|members)$/;
        $val = $role->expandValue($role->prop($key) // 'undef');
        $result .= "| $val ";
      }
      $result .= "|\n";
    }
  }

  if ($this->{_nodes}) {
    my @nodes = $this->getSortedNodes();

    # generate header row
    $result .= "\n---++ Nodes\n| *ID* | *Title* ";
    foreach my $key (sort $nodes[0]->props) {
      $result .= "| *" . ucfirst($key) . "* " unless $key =~ /^(id|title)$/;
    }
    $result .= "|\n";

    # generate data rows
    foreach my $node (@nodes) {
      $result .= "| $node->{id} ";
      my $val = $node->expandValue($node->prop("title"));
      $result .= "| $val ";
      foreach my $key (sort $node->props) {
        next if $key =~ /^(id|title)$/;
        $val = $node->expandValue($node->prop($key) // 'undef');
        $result .= "| $val ";
      }
      $result .= "|\n";
    }
  }

  if ($this->{_edges}) {
    my @edges = $this->getSortedEdges();

    # generate header row
    $result .= "\n---++ Edges\n| *From* | *Action* | *To* ";
    foreach my $key (sort $edges[0]->props) {
      $result .= "| *" . ucfirst($key) . "* " unless $key =~ /^(from|action|to)$/;
    }
    $result .= "|\n";

    # generate data rows 
    foreach my $edge (@edges) {
      $result .= "| $edge->{from} ";
      $result .= "| $edge->{action} ";
      $result .= "| $edge->{to} ";

      foreach my $key (sort $edge->props) {
        next if $key =~ /^(from|action|to)$/;
        my $val = $edge->expandValue($edge->prop($key) // 'undef');
        $result .= "| $val ";
      }
      $result .= "|\n";
    }
  }

  return $result;
}

=begin TML

---++ ObjectMethod getDot($params) -> $tml

returns a TML expression to render the graphviz dot graph

=cut

sub getDot {
  my ($this, $params) = @_;

  return "" unless $this->{_topic}; # test if this net has been finished already

  $params ||= {};
  my $template = $params->{template} // "qm::graph::dot";
  my $result = Foswiki::Func::expandTemplate($template);

  my @nodes = $this->getSortedNodes;
  my $graphNodes = join("\n", map {
      my $attrs = $_->expandValue($_->prop("attributes"));
      $attrs =~ s/"/\\"/g;
      '\"'.$_->{id}.'\" [label=\"'.$_->{title}.'\", '.$attrs.']'
    } 
    @nodes
  );

  my @edges = $this->getSortedEdges;
  my $graphEdges = join("\n", map {
      my $attrs = $_->expandValue($_->prop("attributes"));
      $attrs =~ s/"/\\"/g;
      '\"'.$_->{from}.'\" -> \"'.$_->{to}.'\" [xlabel=\"'.$_->{title}.'\", '.$attrs.']'
    } grep {
      $_->prop("action") ne "_hidden_"
    } @edges
  );

  my %graphRanking = ();
  foreach my $node (@nodes) {
    my $rank = $node->prop("rank");
    next unless defined $rank && $rank ne "";
    push @{$graphRanking{$rank}}, '\"' . $node->prop("id") . '\"';
  }

  my $graphRanking = "";
  foreach my $id (sort keys %graphRanking) {
    $graphRanking .= "{rank = same; ".join("; ", @{$graphRanking{$id}})."}\n";
  }

  my $rankDir = $graphRanking eq "" ? "TB" : "LR";

  $result =~ s/\$graphName/$this->{_topic}/g;
  $result =~ s/\$graphNodes/$graphNodes/g;
  $result =~ s/\$graphEdges/$graphEdges/g;
  $result =~ s/\$graphRanking/$graphRanking/g;
  $result =~ s/\$rankDir/$rankDir/g;

  return $result;
}

=begin TML

---++ ObjectMethod getVis($params) -> $tml

returns a TML expression to render the Vis.js graph

=cut

sub getVis {
  my ($this, $params) = @_;

  return "" unless $this->{_topic}; # test if this net has been finished already

  $params ||= {};
  my $template = $params->{template} // "qm::graph::vis";
  my $result = Foswiki::Func::expandTemplate($template);

  my $graphNodes = "[".join(",\n", map {'{"id": "'.$_->{id}.'", "label": "'.$_->{title}.'"}'} $this->getSortedNodes)."]";
  my $graphEdges = "[".join(",\n", map {'{"from": "'.$_->{from}.'", "to": "'.$_->{to}.'", "label": "'.$_->{title}.'", "arrows":"to"}'} grep {$_->prop("action") ne "_hidden_"} $this->getSortedEdges)."]";
  my $graphOptions = "";
  my $id = "id"._getRandom();

  $result =~ s/\$id/$id/g;
  $result =~ s/\$graphName/$this->{_topic}/g;
  $result =~ s/\$graphNodes/$graphNodes/g;
  $result =~ s/\$graphEdges/$graphEdges/g;
  $result =~ s/\$graphOptions/$graphOptions/g;

  return $result;
}

sub _getRandom {
  return int( rand(10000) ) + 1;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Net $_[0]\n";
}

1;

