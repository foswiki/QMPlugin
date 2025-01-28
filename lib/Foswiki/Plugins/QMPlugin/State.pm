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

package Foswiki::Plugins::QMPlugin::State;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::State

implements a state that a network is in

a topic is in a certain state. one state can transition into another
by following the topological constraints of the underlying network.

=cut

use warnings;
use strict;

use POSIX;
use Foswiki::Func ();
use Foswiki::Attrs ();
use Foswiki::Plugins ();
use Foswiki::Plugins::QMPlugin ();
use Foswiki::Plugins::QMPlugin::Command ();
use Foswiki::Plugins::QMPlugin::Review ();
use Foswiki::Plugins::QMPlugin::Node ();
use Foswiki::Plugins::MultiLingualPlugin ();
use Assert;
use JSON ();
use Error qw(:try);

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0; # toggle me

=begin TML

---++ =ClassProperty= PROPS

definition of all mandatory properties of an object of its kind;
node, edge and role classes each refine this list 

=cut

use constant PROPS => qw(
  author
  changed
  date 
  id 
  previousAction 
  reviewAction
  previousNode 
  origin
  workflow
  approvalRev
);

=begin TML

---++ ClassMethod new($web, $topic, $rev, $meta) -> $state

constructor for a state object

=cut

sub new {
  my $class = shift;
  my $web = shift;
  my $topic = shift;
  my $rev = shift;
  my $meta = shift;

  my $this = bless({
    @_
  }, $class);

  $this->{_queue} = {};

  #_writeDebug("new state $this");
  return $this->init($web, $topic, $rev, $meta);
}


=begin TML

---++ ObjectMethod init($web, $topic, $rev, $meta)

init this state by reading the associated topic; this method is called
as part of the constructor, but may also be called afterwards to assign
a different topic or revision to it.

=cut

sub init {
  my ($this, $web, $topic, $rev, $meta) = @_;

  ($meta) = Foswiki::Func::readTopic($web, $topic, $rev) unless defined $meta;

  $this->{_web} = $web;
  $this->{_topic} = $topic;
  $this->{_meta} = $meta;
  $this->{_reviewCounter} = 0;

  $this->{_rev} = $meta->getLoadedRev() || 0;

  _writeDebug("called init $web.$topic, rev=$this->{_rev} for state $this");

  my $qmData = $meta->get("QMSTATE");

  if ($qmData) {
    #_writeDebug("qmdata found"); 
  } else {
    #_writeDebug("no qmdata found");

    if (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
      _writeDebug("WorkflowPlugin is still enabled ... not migrating data");
    } else {
      # try to init from legacy WORKFLOW data
      my $legacyData = $meta->get("WORKFLOW");

      if ($legacyData) {
        my $legacyHistory = $meta->get("WORKFLOWHISTORY", $legacyData->{"LASTVERSION_".$legacyData->{name}});

        _writeDebug("found legacy data");
        _writeDebug("init'ing from legacy data: id=$legacyData->{name}");
        $qmData = {
          id => $legacyData->{name},
          changed => 1,
          author => Foswiki::Func::getWikiName($legacyHistory->{author}),
          date => $legacyHistory->{date},
          previousAction => $legacyData->{LASTACTION},
          previousNode => $legacyData->{LASTSTATE},
        };

        $this->{_migrateFromLegacy} = 1;

      } else {
        _writeDebug("no legacy found");
      }
    }
  }

  $qmData ||= {};

  # init from topicinfo
  my $info = $meta->getRevisionInfo();
  $qmData->{author} //= $info->{author};
  $qmData->{date} //= $info->{date};

  while (my ($key, $val) = each %$qmData) {
    next if $key =~ /^_/;
    #_writeDebug("key=$key, val=$val");
    $this->{$key} = $val;
  }
  
  # init from qmstate and qmworkflow formfields
  my $workflow;
  my $workflowField = $this->getCore->getQMWorkflowFormfield($meta);
  $workflow = $workflowField->{value} if defined $workflowField;

  my ($fieldDef, $field) = $this->getCore->getQMStateFormfield($meta);
  $workflow = $fieldDef->param("workflow") if $fieldDef && !$workflow;

  $this->setWorkflow($workflow);

  $this->{_reviews} = [];
  foreach my $reviewData ($meta->find("QMREVIEW")) {
    push @{$this->{_reviews}}, Foswiki::Plugins::QMPlugin::Review->new($this, $reviewData);
  }

  # SMELL: no legacy comments are preserved
  my $net = $this->getNet();
  my $defaultNode = $net ? $net->getDefaultNode : undef;
  $this->{id} ||= $defaultNode->prop("id") if defined $defaultNode;

  # traverse the edge when the formfield changed

  if ($net) {

    if (defined($field) && defined($field->{value}) && $field->{value} ne '' && (!defined($qmData->{id}) || $field->{value} ne $qmData->{id})) {

      # traverse to state by field value 
      my $from = $qmData->{id} // '_unknown_'; 
      my $to = $field->{value};
      my $edge = $net->getEdge($from, undef, $to);
      my $user = $this->getCore->getSelf();
      
      if ($edge && $edge->isEnabled($user)) {
        _writeDebug("edge ".$edge->prop("id")." is enabled for ".$user->prop("displayName"));
      } else {
        _writeDebug("WARNING: edge $from -> $to not enabled or allowed while saving topic");
        $edge = undef;
      }

      #_writeDebug("field value=$field->{value}") if defined $field;
      #_writeDebug("qmdata id=$from");

      if ($edge) {
        _writeDebug("need to perform a transition from '$from' to '$to' using action '".$edge->prop("action")."'");
        $this->traverse($edge, "_init_");
        $this->hasChanged(1);
      } else {
        _writeDebug("WARNING: need to resync formfield from '$to' to '$from' in topic $this->{_web}.$this->{_topic}");
        $field->{value} = $from;
        $this->hasChanged(1);
      }
    } elsif (!defined($qmData->{id}) || $qmData->{id} eq '_unknown_') {

      # travese the initial edge to the default node

      my $from = '_unknown_';
      my $to = $net->getDefaultNode();
      my $edge = $net->getEdge($from, undef, $to);

      if ($edge) {
        _writeDebug("performing initial transition");
        $this->traverse($edge, "_init_");
        $this->hasChanged(1);
      } else {
        #_writeWarning("woops, cannot find an initial edge");
      }
    }
  }

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  #_writeDebug("finishing state $this");
  foreach my $review ($this->getReviews()) {
    $review->finish;
  }

  # the net isnt finished here, see core::finish

  undef $this->{_web};
  undef $this->{_topic};
  undef $this->{_rev};
  undef $this->{_meta};
  undef $this->{_queue};
  undef $this->{_origWeb};
  undef $this->{_origTopic};
  undef $this->{_origMeta};
  undef $this->{_net};
  undef $this->{_reviews};
  undef $this->{_lastApproved};
  undef $this->{_json};
}

=begin TML

---++ ObjectMethod setWorkflow($workflow) -> $net

set the workflow definition topic of this state; this is either done
as part of the =init()= method; returns a
Net object when a workflow as set successfully, undef otherwise.

=cut

sub setWorkflow {
  my ($this, $workflow) = @_;

  my $oldWorkflow = $this->prop("workflow") // '';
  $workflow //= $oldWorkflow;
  return unless $workflow;

  my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($this->{_web}, $workflow);
  $web =~ s/\//./g;

  $workflow = "$web.$topic";
  my ($package, $file, $line) = caller;
  _writeDebug("called setWorkflow() for $this->{_web}.$this->{_topic} via $package,$line");

  $this->hasChanged(1) if $oldWorkflow ne $workflow;

  if ($oldWorkflow ne $workflow || !$this->{_net}) {
    $this->{workflow} = $workflow;

    _writeDebug("... changing workflow to $workflow");
    $this->{_net} = $this->getCore->getNet($web, $topic, $this);

    if (defined $this->{_net}) {
      my $node = $this->getCurrentNode();
      if (defined $node && $node->prop("id") eq '_unknown_') {
        _writeDebug("current node is unknown.");
      }
    } else {
      #print STDERR "WARNING: cannot create a net for workflow $workflow\n";
    }
  } else {
    _writeDebug("... no change");
  }

  return $this->{_net};
}

=begin TML

---++ ObjectMethod unsetWorkflow($workflow) -> $net

remove the workflow definition and its net from this state

=cut

sub unsetWorkflow {
  my $this = shift;

  _writeDebug("unsetWorkflow()");

  $this->{workflow} = undef;
  $this->{_net}->finish() if defined $this->{_net};
  $this->{_net} = undef;
}

=begin TML

---++ ObjectMethod props() -> @props

get a list of all known state properties

=cut

sub props {
  my $this = shift;

  my %props = ();
  $props{$_} = 1 foreach grep {!/^_/} (keys %$this, PROPS);

  my @props = sort keys %props;
  return wantarray ? @props : scalar(@props);
}

=begin TML

---++ ObjectMethod prop($key, $val) -> $val

getter/setter of a certain property of this state

=cut

sub prop {
  my ($this, $key, $val) = @_;
  
  return if $key =~ /^_/;

  if (defined $val) { 
    my $oldVal = $this->{$key};
    if (!defined($oldVal) || $oldVal ne $val) {
      $this->{$key} = $val;
      $this->hasChanged(1);
    }
  }

  return $this->{$key};
}

=begin TML

---++ ObjectMethod deleteProp($key) -> $val

remove a property from this state, returns 
the original value

=cut

sub deleteProp {
  my ($this, $key) = @_;
  
  return if $key =~ /^_/;

  my $val = $this->{$key};
  undef $this->{$key};
  $this->hasChanged(1) if defined $val;

  return $val;
}

=begin TML

---++ ObjectMethod expandValue($val) -> $val

expand the given value in the context of the current topic

=cut

sub expandValue {
  my ($this, $val) = @_;

  return "" unless defined $val;

  if ($val && $val =~ /%/) {

    # push context for both: 
    # (1) the workflow topic to get its preference settings and #
    # (2) the actual topic to happen the evaluation on

    my ($workflowWeb, $workflowTopic) = Foswiki::Func::normalizeWebTopicName($this->{_web}, $this->{workflow});
    Foswiki::Func::pushTopicContext($workflowWeb, $workflowTopic);
    Foswiki::Func::pushTopicContext($this->{_web}, $this->{_topic});

    my $meta = $this->getMeta();
    $val = $meta->expandMacros($val);

    Foswiki::Func::popTopicContext();
    Foswiki::Func::popTopicContext();
  }

  return $val;
}

=begin TML

---++ ObjectMethod save(%params) -> $this

save this state into the assigned topic/ params are forwared to Foswiki::Meta::save().

=cut

sub save {
  my $this = shift;
  my %args = @_;

  if ($this->{_saveInProgress}) {
    _writeDebug("save in progress for $this->{_web}.$this->{_topic}");
    return;
  }

  _writeDebug("called save for $this->{_web}.$this->{_topic}");

  # make sure the topic is saved "in its own context"
  Foswiki::Func::pushTopicContext($this->{_web}, $this->{_topic});

  $this->{_saveInProgress} = 1;
  $this->processCommands("beforeSave");

  $args{forcenewrevision} = 1 if $this->{_migrateFromLegacy} || ($this->prop("changed") // '' ne $this->hasChanged());
  undef $this->{_migrateFromLegacy};

  $this->updateCustomProperties();
  $this->updateMeta();
  $this->setACLs();

  $args{dontlog} = 1; # a state change is logged manually using the "traverse" action
  $args{minor} = 1; # a state change is a minor change, not a content change

  $this->getCore->saveMeta($this->getMeta, %args);
  $this->processCommands("afterSave");

  $this->{_saveInProgress} = 0;

  Foswiki::Func::popTopicContext();

  return $this;
}

=begin TML

---++ ObjectMethod updateMeta() -> $this

save this state into the assigned meta object, don't save it to the store actually

=cut

sub updateMeta {
  my $this = shift;

  _writeDebug("called updateMeta");

  my $hasChanged = $this->hasChanged();
  my $meta = $this->getMeta();
  my $oldData = $meta->get("QMSTATE");
  my $node = $this->getCurrentNode();

  my $net = $this->getNet();
  if (defined $net && defined $this->{workflow} && $this->{workflow} ne '') {
    _writeDebug("... setting state");

    # set props before saving
    $this->{date} = time;
    $this->{author} = Foswiki::Func::getWikiName();
    my $defaultNode = $net->getDefaultNode;
    $this->{id} ||= $defaultNode->prop("id") if $defaultNode;
    $this->prop("changed", $this->hasChanged());

    # sync qmstate formfield
    my $qmStateField = $this->getCore->getQMStateFormfield($meta);
    if ($qmStateField) {
      _writeDebug("... found qmstate field $qmStateField->{name}, setting value from $qmStateField->{value} to $this->{id}");
      $qmStateField->{value} = $this->{id};
    } else {
      my $fieldDef = $this->getCore->getFormfieldDefinition($meta, "qmstate");
      if ($fieldDef) {

        # adding field not present still required
        _writeDebug("... adding a field $fieldDef->{name} missing in the data");
        $meta->putKeyed("FIELD", {
          name => $fieldDef->{name},
          title => $fieldDef->{title},
          value => $this->{id},
        });
      }
    }

    # test for changes
    my %data = ();
    foreach my $key ($this->props) {
      next if $key eq 'attributes';
      my $val = $this->prop($key);
      next unless defined $val && $val ne "";
      $val = $this->expandValue($val);
      $data{$key} = $val;

      my $oldVal = $oldData->{$key};
      if ($key ne "date" && (!defined($oldVal) || $val ne $oldVal)) {
        $hasChanged = 1;
      }
    }

    if ($hasChanged) {
      _writeDebug("... qmstate changed");
      $meta->remove("QMSTATE");
      $meta->remove("QMREVIEW");

      unless (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
        $meta->remove("WORKFLOW");
        $meta->remove("WORKFLOWHISTORY");
      }

      # cache the revision being approved
      if ($this->isApproved) {
        $data{approvalRev} = $this->getRevision() + 1; # SMELL: soon to be saved
      } else {
        $data{approvalRev} //= ($this->getLastApproved ? $this->getLastApproved->getRevision() : '');
      }

      # store QMSTATE
      $meta->put("QMSTATE", \%data);

      # store QMREVIEWs
      foreach my $review ($this->getReviews()) {
        $review->store($meta);
      }

    } else {
      _writeDebug("... qmstate did not change");
    }

  } else {

    # deleting the state as well as all managed properties

    _writeDebug("deleting state"); 

    $meta->remove("QMSTATE");
    $meta->remove("QMREVIEW");
    $meta->remove("PREFERENCE", "ALLOWTOPICAPPROVE");

    # TODO: remove settings if managed ... not by default for non-qm topics
#    $meta->remove("PREFERENCE", "VIEW_TEMPLATE");
#    $meta->remove("PREFERENCE", "EDIT_TEMPLATE");
#    $meta->remove("PREFERENCE", "PRINT_TEMPLATE");

    unless (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
      $meta->remove("WORKFLOW");
      $meta->remove("WORKFLOWHISTORY");
    }
  }

  _writeDebug("... done updateMeta");

  return $this;
}

=begin TML

---++ ObjectMethod change($action, $to, $comment, $user, $keepReviews) -> $boolean

change this state by performing a certain action, providing an optional comment;
returns true if the action was successfull and the state has been transitioned along the lines
of the net. Otherwise an error is thrown. Note that only the properties of this state
are changed; it is _not_ stored into the current topic; you must call the =save()= method
to do so.

The =keepReviews= boolean allows to keep review objects from a previous transition.
Previous review objects will be filtered out not matching the current action.

=cut

sub change {
  my ($this, $action, $to, $comment, $user, $keepReviews) = @_;

  _writeDebug("called change state id=$this->{id}, action=".($action//'undef').", to=".($to//'undef'));

  _writeDebug("... keeping previous reviews") if $keepReviews;

  my $node = $this->getCurrentNode();
  throw Error::Simple("Woops, current node is invalid.") unless defined $node;

  $user //= $this->getCore->getSelf();
  my $wikiName = $user->prop("wikiName");

  foreach my $edge ($this->getPossibleEdges()) {
    #_writeDebug("... edge=".$edge->prop("id").", action='".$edge->prop("action")."'");

    next if defined($action) && $action ne $edge->prop("action");
    next if defined($to) && $to ne $edge->prop("to");

    # check review progress
    $this->filterReviews($action) unless $keepReviews;

    # check reviewer
    throw Error::Simple("$wikiName already reviewed current state.")
      if $this->isParallel && $this->isReviewedBy($user);

    my $review = $this->addReview({
        "from" => $this->{id},
        "action" => $action,
        "to" => $to,
        "author" => $wikiName,
        "comment" => $comment//'',
      }
    );

    $this->hasChanged(1);

    # check signoff
    my $minSignOff = $edge->getSignOff();
    my $doTraversal = 0;

    if ($edge->isRelativeSignOff) {
      my $signOff = $this->getCurrentSignOff($edge);

      # set signoff if required
      $review->prop("signOff", $signOff) if $minSignOff;

      #_writeDebug("minSignOff=$minSignOff, signOff=$signOff");
      $doTraversal = 1 if $signOff >= $minSignOff;
    } else {
      my $numReviews = $this->getNumReviews($edge);
      #_writeDebug("minSignOff=$minSignOff, numReviews=$numReviews");
      $doTraversal = 1 if $numReviews >= $minSignOff;
    }

    # traverse edge if signoff is reached
    if ($doTraversal) {
      _writeDebug("... do traversal");
      $this->traverse($edge, $comment);
    } else {
      _writeDebug("... not yet traversing edge");
      $this->prop("reviewAction", $action);
    }

    return 1;
  }

  throw Error::Simple("Action not allowed.");
}

=begin TML

---++ ObjectMethod resetReviews() -> $boolean

reset an ongoing parallel review to the start.
returns true if any review was found and deleted

=cut

sub resetReviews {
  my $this = shift;

  _writeDebug("resetReviews");

  my $hasChanged = 0;
  foreach my $review ($this->getReviews()) {
    $review->finish;
    $hasChanged = 1;
  }

  $this->deleteProp("reviewAction");
  $this->{_reviews} = [];

  return $hasChanged;
}

=begin TML

---++ ObjectMethod filterReviews($action, $id) -> $boolean

removes any review that does not the given state and action parameters,
returns true if an review has been deleted.

=cut

sub filterReviews {
  my ($this, $action, $id) = @_;

  $action ||= $this->prop("reviewAction") || '';
  $id ||= $this->getCurrentNode->prop("id");

  #_writeDebug("filterReviews not matching id=$id, action=$action");

  my $hasChanged = 0;
  my @reviews = ();

  foreach my $review (@{$this->{_reviews}}) {

    if (($review->prop("from") // '') eq $id && ($review->prop("action") // '') eq $action) {
      #_writeDebug("keeping review ".$review->stringify);
      push @reviews, $review;
    } else {
      #_writeDebug("DELETING review ".$review->stringify);
      $review->finish;
      $hasChanged = 1;
    }
  }

  $this->deleteProp("reviewAction") unless @reviews;
  $this->{_reviews} = \@reviews;

  return $hasChanged;
}


=begin TML

---++ ObjectMethod traverse($edge, $comment) 

change the current state by traversing the given edge;
note that this only changes the current location within the net; the changed data is _not_ stored
into the current state.

=cut

sub traverse {
  my ($this, $edge, $comment) = @_;

  my $fromNode = $edge->fromNode();
  my $toNode = $edge->toNode();
  my $command = $edge->prop("command");

  _writeDebug("called traverse from ".$fromNode->prop("id")." to ".$toNode->prop("id")." via action ".$edge->prop("action").($comment?" comment '$comment'":"").($command?" executing $command":""));

  $this->{previousNode} = $fromNode->prop("id"); 
  $this->{previousAction} = $edge->prop("action");
  $this->{id} = $toNode->prop("id");

  # compute properties
  $this->updateCustomProperties($toNode);

  # execute all commands
  $edge->execute($this);

  # queue internal notify command about new state; will be processed after save
  $this->queueCommand($edge, "notify");

  $this->log($edge, $comment);
}

=begin TML

---++ ObjectMethod updateCustomProperties()

recompute all custom node properties and store them into the state

=cut

sub updateCustomProperties {
  my ($this, $node) = @_;

  $node ||= $this->getCurrentNode();
  return unless $node;

  my %knownNodeProps = map {$_ => 1} Foswiki::Plugins::QMPlugin::Node::PROPS;
  my $stateRegex = join("|", $this->props);

  foreach my $key ($node->props) {
    next if $knownNodeProps{$key} || $key =~ /^_/;

    my $val = $node->prop($key);

    if (defined($val) && $val ne "") {
      $val =~ s/\$($stateRegex)\b/$this->expandValue($this->prop($1))/ge;
      $val = $this->expandValue($val);
    }

    if (defined($val) && $val ne "") {
      $this->prop($key, $val);
    } else {
      $this->deleteProp($key);
    }
  }
}

=begin TML

---++ ObjectMethod log($edge, $comment)

write the event of traversing the given edge to the wki logs
with an optional comment

=cut

sub log {
  my ($this, $edge, $comment) = @_;

  # don't log hidden edges
  return if $edge->prop("action") eq '_hidden_';

  my $session = $Foswiki::Plugins::SESSION;
  my $message = 
    "from=" . $edge->fromNode->prop("id") . 
    ", action=" . $edge->prop("action") . 
    ", to=" . $edge->toNode->prop("id") .
    ", comment=".($comment//'') .
    ", workflow=".($this->{workflow}//'');

  #print STDERR "QMSTATE: log $message\n";

  $session->logger->log({
    level => 'info',
    action => 'traverse',
    webTopic => "$this->{_web}.$this->{_topic}",
    extra => $message,
  });
}

=begin TML

---++ ObjectMethod queueCommand($edge, $id, $params)

queue the command of an edge being traversed

=cut

sub queueCommand {
  my ($this, $edge, $id, $params) = @_;

  return unless $edge;
  return unless $id;

  foreach my $handler ($this->getCore->getCommandHandlers($id)) {
    my $command = Foswiki::Plugins::QMPlugin::Command->new($handler, $edge, $params);
    push @{$this->{_queue}{$handler->{type}}}, $command if $command;
  }
}

=begin TML

---++ ObjectMethod processCommands($type)

commands are processed after this state has been saved, not earlier, as 
some commands handler might alter the store of the changed state, such as moving
the related topic to the trash.

=cut

sub processCommands {
  my ($this, $type) = @_;

  _writeDebug("processCommands($type)");

  foreach my $command (@{$this->{_queue}{$type}}) {
    $command->execute($this);
  }

  # clear queue
  $this->{_queue}{$type} = ();

  _writeDebug("... done processCommands($type)");
}

=begin TML

---++ ObjectMethod sendNotification($template) -> $errors

sends a notifications for the current edge transition. This is called when a transition
has actually happened, but may also be called later on to re-send the email notification.
this method is always called when =save()= is performed; the method returns a list of errors
that may have happened as part of the mail delivery process. See also =Foswiki::Func::sendEmail=.

=$template= is the name of the template to be used for the email, defaults to =qmpluginnotify=.

=cut

sub sendNotification {
  my ($this, $template) = @_;

  _writeDebug("sendNotification()");

  my $edge = $this->getCurrentEdge();

  _writeDebug("... woops, current edge not found") unless defined $edge;
  return unless defined $edge;

  my @emails = $edge->getEmails();
  my $doNotifySelf = Foswiki::Func::getPreferencesFlag("QMPLUGIN_NOTIFYSELF");
  unless ($doNotifySelf) {
    my %myEmails = map {$_ => 1} Foswiki::Func::wikinameToEmails();
    @emails = grep {!$myEmails{$_}} @emails;
  }

  if (@emails) {
    _writeDebug("... emails=@emails");
  } else {
    _writeDebug("... no emails found in edge: ".$edge->stringify) if TRACE;
    return;
  }

  $template ||= $this->getNotificationTemplate($edge);
  _writeDebug("template=$template");
  Foswiki::Func::readTemplate($template);

  my $id = $this->expandValue($edge->prop("to"));
  my (undef, $workflow) = Foswiki::Func::normalizeWebTopicName($this->{_web}, $this->prop("workflow"));

  _writeDebug("workflow=$workflow, id='$id'");

  my $tmpl;
  foreach my $key ("qm::notify::".$workflow."::".$id, "qm::notify::".$id, "qm::notify") {
    $tmpl = Foswiki::Func::expandTemplate($key);
    if ($tmpl) {
      _writeDebug("... found tmpl for $key");
      last;
    }
  }

  _writeDebug("...woops, empty template") unless $tmpl;
  return unless $tmpl;

  #_writeDebug("... tmpl=$tmpl");

  # set preference values used in email template
  # - qm_emails
  # - qm_fromNode
  # - qm_fromNodeTitle
  # - qm_action
  # - qm_actionTitle
  # - qm_toNode
  # - qm_toNodeTitle
  # - qm_author
  # - qm_authorTitle
  my $author = $this->getCore->getUser($this->prop("author"));
  Foswiki::Func::setPreferencesValue("qm_emails", join(", ", @emails));
  Foswiki::Func::setPreferencesValue("qm_fromNode", $edge->fromNode->prop("id"));
  Foswiki::Func::setPreferencesValue("qm_fromNodeTitle", $edge->fromNode->prop("title"));
  Foswiki::Func::setPreferencesValue("qm_action", $edge->prop("id"));
  Foswiki::Func::setPreferencesValue("qm_actionTitle", $edge->prop("title"));
  Foswiki::Func::setPreferencesValue("qm_toNode", $edge->toNode->prop("id"));
  Foswiki::Func::setPreferencesValue("qm_toNodeTitle", $edge->toNode->prop("title"));
  Foswiki::Func::setPreferencesValue("qm_author", $author->prop("wikiName"));
  Foswiki::Func::setPreferencesValue("qm_authorTitle", $author->prop("displayName"));
 
  my $text = $this->expandValue($tmpl);

  $text =~ s/^\s+//g;
  $text =~ s/\s+$//g;

  if ($text =~ /^To: *$/m) {
    _writeDebug("... no recipient");
    return;
  }

  unless ($text) {
    _writeDebug("...woops, email text empty");
    return;
  }

  _writeDebug("...email=$text");

  Foswiki::Func::writeEvent("sendmail", "to=".join(", ", sort @emails)." subject=traverse from ".$edge->fromNode->prop("id")." action ".$edge->prop("id")." to ".$edge->toNode->prop("id"));
  my $errors = Foswiki::Func::sendEmail($text, 3);
 
  if ($errors) {
    Foswiki::Func::writeWarning("Failed to send mails: $errors");
    _writeDebug("Failed to send mails: $errors");
  } else {
    _writeDebug("... sent email successfully");
  }
 
  return $errors;
}
=begin TML

---++ ObjectMethod getNotificationTemplate($edge) -> $templateName

get the name of the template for the given edge. if the edge doesn't have
a =mailTemplate= property will the QMNet's default net be used. 
See Foswiki::Plugins::QMPlugin::Net::getNotificationTemplate().

=cut

sub getNotificationTemplate {
  my ($this, $edge) = @_;

  $edge ||= $this->getCurrentEdge();

  my $template = $this->expandValue($edge->prop("mailTemplate"));
  $template =~ s/^\s+//;
  $template =~ s/\s+$//;
  $template ||= $this->getNet->getNotificationTemplate();

  return $template;
}

=begin TML

---++ ObjectMethod setACLs($node) -> $boolean

sets the ACLs as imposed by the current node of the state or the specified one;
this method is called by =save()= itself and probably of no direct use otherwise.

returns true if acls changed and false if no change was needed.

=cut

sub setACLs {
  my ($this, $node) = @_;

  my $hasChanged = 0;

  _writeDebug("called setACLs");
  $node ||= $this->getCurrentNode();
  my $meta = $this->getMeta();

  #_writeDebug("... no current node") unless defined $node;

  unless (defined $node) {

    # nuke all existing acls
    foreach my $key (qw(ALLOWTOPICCHANGE 
                        ALLOWTOPICVIEW 
                        ALLOWTOPICAPPROVE
                        PERMSET_CHANGE 
                        PERMSET_CHANGE_DETAILS 
                        PERMSET_VIEW 
                        PERMSET_VIEW_DETAILS)) {
      $meta->remove('PREFERENCE', $key);
    }

    _writeDebug("... done setACLs");
    return 0;
  }

  my $oldAllowView = $meta->get("PREFERENCE", "ALLOWTOPICVIEW");
  my $oldAllowEdit = $meta->get("PREFERENCE", "ALLOWTOPICCHANGE");
  my $oldAllowApprove = $meta->get("PREFERENCE", "ALLOWTOPICAPPROVE");

  $oldAllowView = $oldAllowView ? join(", ", sort split(/\s*,\s*/, $oldAllowView->{value})) : "";
  $oldAllowEdit = $oldAllowEdit ? join(", ", sort split(/\s*,\s*/, $oldAllowEdit->{value})) : "";
  $oldAllowApprove = $oldAllowApprove ? join(", ", sort split(/\s*,\s*/, $oldAllowApprove->{value})) : "";

  #_writeDebug("... old allow view : $oldAllowView");
  #_writeDebug("... old allow change : $oldAllowEdit");
  #_writeDebug("... old allow approve : $oldAllowApprove");

  #_writeDebug("... node=".$node->stringify);

  my @allowEdit = $node->getACL("allowEdit");
  #_writeDebug("... new allow change: @allowEdit");

  my $allowEdit = join(", ", sort @allowEdit);
  if ($allowEdit ne $oldAllowEdit) {
    #_writeDebug("... setting allowEdit to $allowEdit");

    $meta->remove("PREFERENCE", "ALLOWTOPICCHANGE");
    $meta->remove("PREFERENCE", "PERMSET_CHANGE");
    $meta->remove("PREFERENCE", "PERMSET_CHANGE_DETAILS");

    if (@allowEdit) {
      $meta->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICCHANGE',
        title => 'ALLOWTOPICCHANGE',
        value => $allowEdit,
        type  => 'Set'
      });
      $meta->putKeyed('PREFERENCE', {
        name  => 'PERMSET_CHANGE',
        title => 'PERMSET_CHANGE',
        value => 'details',
        type  => 'Set'
      });
      $meta->putKeyed('PREFERENCE', {
        name  => 'PERMSET_CHANGE_DETAILS',
        title => 'PERMSET_CHANGE_DETAILS',
        value => $allowEdit,
        type  => 'Set'
      });
    }
    $hasChanged = 1;
  } else {
    #_writeDebug("... allowEdit did not change");
  }

  my @allowView = $node->getACL("allowView");
  #_writeDebug("... new allow view: @allowView");

  my $allowView = join(", ", sort @allowView);
  if ($allowView ne $oldAllowView) {
    #_writeDebug("... setting allowView to @allowView");

    $meta->remove("PREFERENCE", "ALLOWTOPICVIEW");
    $meta->remove("PREFERENCE", "PERMSET_VIEW");
    $meta->remove("PREFERENCE", "PERMSET_VIEW_DETAILS");

    if (@allowView) {
      $meta->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICVIEW',
        title => 'ALLOWTOPICVIEW',
        value => $allowView,
        type  => 'Set'
      });
      $meta->putKeyed('PREFERENCE', {
        name  => 'PERMSET_VIEW',
        title => 'PERMSET_VIEW',
        value => 'details',
        type  => 'Set'
      });
      $meta->putKeyed('PREFERENCE', {
        name  => 'PERMSET_VIEW_DETAILS',
        title => 'PERMSET_VIEW_DETAILS',
        value => $allowView,
        type  => 'Set'
      });
    }
    $hasChanged = 1;
  } else {
    #_writeDebug("... allowView did not change");
  }

  my @allowApprove = $this->getPossibleReviewers();
  my $allowApprove = join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} @allowApprove);

  if ($allowApprove ne $oldAllowApprove) {

    $meta->remove("PREFERENCE", "ALLOWTOPICAPPROVE");

    if (@allowApprove) {
      #_writeDebug("... setting new allowApprove to $allowApprove");
      $meta->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICAPPROVE',
        title => 'ALLOWTOPICAPPROVE',
        value => $allowApprove,
        type  => 'Set'
      });
    }

    $hasChanged = 1;
  } else {
    #_writeDebug("... allowApprove did not change");
  }

  _writeDebug("... done setACLs ... hasChanged=$hasChanged");
  return $hasChanged
}

=begin TML

---++ ObjectMethod getWeb() -> $web

get the web of this state

=cut

sub getWeb {
  my $this = shift;

  return $this->{_web};
}

=begin TML

---++ ObjectMethod getTopic() -> $topic

get the topic of this state

=cut

sub getTopic {
  my $this = shift;

  return $this->{_topic};
}

=begin TML

---++ ObjectMethod getMeta() -> $meta

get the meta object of this state

=cut

sub getMeta {
  my $this = shift;

  return $this->{_meta};
}

=begin TML

---++ ObjectMethod getRevision() -> $rev

get the revision of the topic of this state

=cut

sub getRevision {
  my $this = shift;

  return $this->{_rev};
}

=begin TML

---++ ObjectMethod getLastApproved($force) -> $state

get the state that was last approved starting at the current rev.
if $force is set the last revision will be digged out by a search.
the =approvalRev= property will be used otherwise.

=cut

sub getLastApproved {
  my ($this, $force) = @_;

  my $net = $this->getNet();
  return unless $net;

  $force //= 0;
  _writeDebug("called getLastApproved force=$force");

  my $state = $this->{_lastApproved};
  return $state if $state;

  my $rev = $force ? undef: $this->{approvalRev};
  _writeDebug("...rev=".($rev//'undef'));

  if (defined $rev) {
    return if $rev eq "";
    $state = $this->getCore->getState($this->{_web}, $this->{_topic}, $rev);
  } else {

    for (my $i = $this->{_rev}; $i > 0; $i--) {
      my $s = $this->getCore->getState($this->{_web}, $this->{_topic}, $i);
      next unless $s && $s->prop("id");
      next unless $s->prop("changed") || $i == 1;
      next unless $s->isApproved();

      $state = $s;
      last;
    }
  }
  $this->{_lastApproved} = $state;

  return $state;
}

=begin TML

---++ ObjectMethod getReviews() -> @reviews

get all reviews of this state

=cut

sub getReviews {
  my $this = shift;

  my @result = sort {$a->prop("date") <=> $b->prop("date")} @{$this->{_reviews}};
  return @result;
}

=begin TML

---++ ObjectMethod numReviews() -> integer

get the number of reviews in this state

=cut

sub numReviews {
  my $this = shift;

  return scalar(@{$this->{_reviews}});
}

=begin TML

---++ ObjectMethod numComments() -> integer

get the number of reviews in this state

=cut

sub numComments {
  my $this = shift;

  return scalar(grep {
    my $comment = $_->prop("comment"); 
    defined($comment) && $comment ne ""
  } @{$this->{_reviews}});
}

=begin TML

---++ ObjectMethod getReviewEdge() -> $edge

get the edge that has been reviewed

=cut

sub getReviewEdge {
  my $this = shift;

  my $edge;
  my $action = $this->prop("reviewAction");
  my $net = $this->getNet();
  return unless $net;

  $edge = $net->getEdge($this->getCurrentNode, $action) if $action;

  return $edge;
}

=begin TML

---++ ObjectMethod getCurrentNode() -> $node

get the node that this state is currently associated with

=cut

sub getCurrentNode {
  my $this = shift;

  my $net = $this->getNet;
  return unless $net;

  my $id = $this->{id} // '_unknown_';
  return $net->getNode($id) // $net->getUnknownNode();
}

=begin TML

---++ ObjectMethod getCurrentEdge() -> $edge

get the edge that has been traversed to reach this state

=cut

sub getCurrentEdge {
  my $this = shift;

  #_writeDebug("getCurrentEdge");
  my $action = $this->{previousAction};
  return unless defined $action;

  #_writeDebug("action=$action, previousNode=$this->{previousNode}");
  my $net = $this->getNet;
  return unless $net;

  my $edge = $net->getEdge($this->{previousNode}, $action, $this->{id});
  return unless defined $edge;

  return $edge;
}


=begin TML

---++ ObjectMethod getNet() -> $net

get the net that this state is currently associated with

=cut

sub getNet {
  my $this = shift;

  my $net = $this->{_net};
  $net->setState($this) if $net;
  return $net;
}

=begin TML

---++ ObjectMethod getPossibleActions($node, $user) -> @actions

get the list of possible actions starting from the current node or the node specified 
in the call; the empty list is returned when user is not allowed
to perform any actions

=cut

sub getPossibleActions {
  my ($this, $node, $user) = @_;

  my %actions = map { $_->prop("action") => 1 } $this->getPossibleEdges($node, $user);

  my @actions = sort keys %actions;
  return @actions;
}

=begin TML

---++ ObjectMethod getTriggerableActions($node, $user) -> @actions;

get a list of actions that might be triggered

=cut

sub getTriggerableActions {
  my ($this, $node, $user) = @_;

  my %actions = map { $_->prop("action") => 1 } $this->getTriggerableEdges($node, $user);

  my @actions = sort keys %actions;
  return @actions;
}

=begin TML

---++ ObjectMethod getPossibleEdges($node, $user) -> @actions

get the list of possible edges starting from the current node or the node specified 
in the call; the empty list is returned when user is not allowed
to perform any actions

=cut

sub getPossibleEdges {
  my ($this, $node, $user) = @_;

  $user //= $this->getCore->getSelf();
  $node //= $this->getCurrentNode();

  #_writeDebug("called getPossibleEdges node=".($node?$node->prop("id"):"undef").", user=".$user->prop("wikiName"));

  my @edges = ();

  if ($user) {
    unless ($this->isParallel() && $this->isReviewedBy($user)) {
      if (defined $node) {
        foreach my $edge ($node->getOutgoingEdges()) {
          push @edges, $edge if $edge->isEnabled($user);
        }
      }
    }
  }

  #_writeDebug("... found ".scalar(@edges)." edge(s)");

  return @edges;
}

=begin TML

---++ ObjectMethod getTriggerableEdges($node, $user) -> @actions;

get a list of edges that might be triggered

=cut

sub getTriggerableEdges {
  my ($this, $node, $user) = @_;

  _writeDebug("called getTriggerableEdges");

  my @edges = ();

  $user //= $this->getCore->getSelf();
  $node //= $this->getCurrentNode();
  
  if (defined $node && defined $user) {

    foreach my $edge ($node->getOutgoingEdges()) {
      _writeDebug("testing edge ".$edge->stringify);
      next unless $edge->isTriggerable($user);

      _writeDebug("... found triggerable edge");
      push @edges, $edge;
    }
  }

  return @edges;
}

=begin TML

---++ ObjectMethod isReviewedBy($user) -> $boolean

returns true when the current state has been reviewed by user already

=cut

sub isReviewedBy {
  my ($this, $user) = @_;

  $user //= $this->getCore->getSelf();

  if ($this->{_reviews} && defined $user) {
    foreach my $review ($this->getReviews()) {
      return ($review->prop("from") // '_unknown_') eq $this->{id} && (
        $review->prop("author") eq $user->prop("id") ||
        $review->prop("author") eq $user->prop("userName") ||
        $review->prop("author") eq $user->prop("wikiName") 
      );
    }
  }

  return 0;
}

=begin TML

---++ ObjectMethod isParallel() -> $boolean

returns true when there the current review actions must be signed off by multiple users

=cut

sub isParallel {
  my $this = shift;

  my $edge = $this->getReviewEdge();

  return 0 unless defined $edge;
  return 1 if $edge->getSignOff > 0;
  return 0;
}

=begin TML

---++ ObjectMethod isApproved($node) -> $boolean

returns true if the given or current node of the state is an
approval node

=cut

sub isApproved {
  my ($this, $node) = @_;

  $node //= $this->getCurrentNode;

  return $node && $node->isApprovalNode ? 1 : 0;
}

=begin TML

---++ ObjectMethod hasChanged() -> $boolean

returns true when this state was changed as part of a transition, returns false if other
changes happened to the topic

=cut

sub hasChanged {
  my ($this, $val) = @_;

  $this->{_gotChange} = $val if defined $val;
  return $this->{_gotChange} ? 1:0;
}

=begin TML

---++ ObjectMethod getCurrentSignOff($edge) -> $percent

get the current sign-off progress counting the number of people
that already reviewed this state

=cut

sub getCurrentSignOff {
  my ($this, $edge) = @_;

  #_writeDebug("getCurrentSignOff");
  $edge ||= $this->getReviewEdge();
  return 0 unless defined $edge;

  #_writeDebug("edge: ".$edge->stringify);

  my $numReviews = $this->getNumReviews($edge);
  return 0 unless $numReviews;

  my @allowed = $edge->getReviewers;
  #_writeDebug("allowed=@allowed");
  return 1 unless @allowed;

  my $signOff = $numReviews / scalar(@allowed);
  #_writeDebug("signOff=$signOff");

  return $signOff;
}

=begin TML

---++ ObjectMethod addReview($data) 

create a new review of this state

=cut

sub addReview {
  my ($this, $data) = @_;

  my $review = Foswiki::Plugins::QMPlugin::Review->new($this, $data);
  #_writeDebug("adding new review ".$review->stringify);

  push @{$this->{_reviews}}, $review;

  return $review;
}

=begin TML

---++ ObjectMethod getReviewers($action) -> @users

get the list of users that already reviewed the current state 

=cut

sub getReviewers {
  my ($this, $action) = @_;

  my %users = ();

  foreach my $review ($this->getReviews()) {
    if (!defined($action) || $action eq $review->prop("action")) {
      my $user = $this->getCore->getUser($review->prop("author"));
      $users{$user->prop("id")} = $user if defined $user;
    }
  }
  
  return values %users;
}

=begin TML

---++ ObjectMethod getNumReviews($edge) -> $number

returns the number of people that already reviewed the current state
using the given action

=cut

sub getNumReviews {
  my ($this, $edge) = @_;

  return scalar($this->getReviewers($edge->prop("action")));
}

=begin TML

---++ ObjectMethod getComments() -> @comments

get the list of comments in reviews; each item in the result list has properties:

   * author
   * date
   * text

=cut

sub getComments {
  my $this = shift;

  my @comments = ();

  foreach my $review ($this->getReviews()) {
    my $comment = $review->prop("comment");

    push @comments, {
      author => $review->prop("author"),
      date => $review->prop("date"),
      text => $review->prop("comment"), 
    };
  }
  
  return @comments;
}

=begin TML

---++ ObjectMethod getPossibleReviewers($from, $action, $to) -> @users

get the list of allowed users of outgoing edges, optionally performing
a certain action; returns an empty list there are no specific restrictions,
that is _all_ users may perform a certain action

=cut

sub getPossibleReviewers {
  my ($this, $from, $action, $to) = @_;

  $from //= $this->getCurrentNode();

  my %reviewers = ();

  if (defined $from) {

    foreach my $edge ($from->getOutgoingEdges) {
       next unless $edge->isEnabled();

      if (defined $action) {
        my $edgeAction = $$edge->prop("action");
        next unless $edgeAction eq $action;
      }
      if (defined $to) {
        $to = $to->prop("id") if ref($to);
        next unless $edge->prop("to") eq $to;
      }
      my @reviewers = $edge->getReviewers();

      unless (@reviewers) {
        # no restrictions found
        %reviewers = ();
        last;
      }
      
      $reviewers{$_->prop("id")} = $_ foreach @reviewers;
    }

    if ($this->isParallel) {
      delete $reviewers{$_->prop("id")} foreach $this->getReviewers;
    }
  }

  return values %reviewers;
}

=begin TML

---++ ObjectMethod getPendingApprovers($node) -> @users

get the list of users that still need to approve the current state

=cut

sub getPendingApprovers {
  my ($this, $node) = @_;

  $node //= $this->getCurrentNode();

  my @users = ();
  foreach my $approval (@{$this->getNet->getApprovalNodes()}) {
    push @users, $this->getPossibleReviewers($node, undef, $approval);
  }

  return @users;
}

=begin TML

---++ ObjectMethod getPendingReviewers($edge) -> @users

get the list of users that still need to review the current state

=cut

sub getPendingReviewers {
  my ($this, $edge) = @_;

  $edge ||= $this->getReviewEdge();
  return unless defined $edge;

  my %reviewers = ();

  $reviewers{$_->prop("id")} = $_ foreach $edge->getReviewers;
  delete $reviewers{$_->prop("id")} foreach $this->getReviewers;

  return values %reviewers;
}

=begin TML

---++ ObjectMethod reroute($web, $topic, $meta)

create a copy of the underlying topic and continue the state there

=cut

sub reroute {
  my ($this, $web, $topic, $target) = @_;

  my $source = $this->getMeta();

  ($target) = Foswiki::Func::readTopic($web, $topic) unless defined $target;

  $target->text($source->text());
  $target->copyFrom($source);

  $this->prop("origin", $this->{_web}.".".$this->{_topic});
  $this->{_web} = $web;
  $this->{_topic} = $topic;
  $this->{_meta} = $target;

  return $this;
}

=begin TML

---++ ObjectMethod reassign($to) 

change meta object part of this state

=cut

sub reassign {
  my ($this, $to) = @_;

  $this->{_web} = $to->web;
  $this->{_topic} = $to->topic;
  $this->{_meta} = $to;

  return $this;
}

=begin TML

---++ ObjectMethod render($format) -> $string

render the properties of this object given the specified format string 

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $net = $this->getNet();
  return "" unless defined $net;

  my $defaultNode = $net->getDefaultNode;
  my $defaultID = $defaultNode ? $defaultNode->prop("id") : "???";

  my $approvals = $net->getApprovalNodes;
  my $approvalID = @$approvals? $approvals->[0]->prop("id") : ''; 
  my $approvalIDs = join(", ", map {$_->prop("id")} @$approvals);

  my $adminRole = $net->getAdminRole;
  my $adminID = $adminRole?$adminRole->prop("id"):'';

  my $node = $this->getCurrentNode();
  return "" unless defined $node;
  #_writeDebug("node=".join(",", $node->props));

  my $result = $format || '';

  my $edge = $this->getCurrentEdge();
  my $notify = "";
  if ($result =~ /\$notify\b/) {
    $notify = $edge ? join(", ", sort map {$_->prop("id")} $edge->getNotify()):"";
  }
  my $emails = "";
  if ($result =~ /\$emails\b/) {
    $emails = $edge?join(", ", sort $edge->getEmails()):"";
  }

  my $numActions = 0;
  my $actions = "";
  if ($result =~ /\$(actions|numActions)\b/) {
    my @actions = sort grep {!/_hidden_/} $this->getPossibleActions();
    $actions = join(", ", @actions);
    $numActions = scalar(@actions);
  }

  my $numEdges = 0;
  my $edges = "";
  my $nodes = "";
  if ($result =~ /\$(edges|nodes|numEdges)\b/) {

    my @edges = sort {$a->index <=> $b->index} grep {$_->prop("action") ne "_hidden_"} $this->getPossibleEdges();
    $edges = join(", ", map {$_->prop("from") . "/" . $_->prop("action"). "/" . $_->prop("to")} @edges);
    $numEdges = scalar(@edges);

    my %nodes = map {$_->prop("to") => 1} @edges;
    $nodes = join(", ", sort keys %nodes);
  }

  # state props
  my $stateRegex = join("|", $this->props);
  my $date = $this->prop("date");
  my $duration = time() - $this->prop("date");
  my $isParallel = $this->isParallel();
  my $previousState = $this->prop("previousNode") || ''; # alias

  my $pendingReviewers = "";
  my $hasPending = 0;
  if ($result =~ /\$(hasPending|pendingReviewers)\b/) {
    my @pendingReviewers = $this->getPendingReviewers();
    $pendingReviewers = join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} @pendingReviewers);
    $hasPending = scalar(@pendingReviewers)?1:0;
  }

  my $roles = "";
  if ($result =~ /\$roles\b/) {
    $roles = join(", ", map {$_->prop("id")} $net->getRoles());
  }

  my $json = "";
  if ($result =~ /\$json\b/) {
    $json = $this->json->pretty->encode($this->asJson($params));
  }

  my @comments = grep {$_->{text} !~ /^\s*$/} $this->getComments();
  my $hasComments = scalar(@comments)?1:0;
  my $comments = join(", ", map {$_->{text}} @comments);
  my $comment = scalar(@comments) ? $comments[-1]->{text} : "";

  my $reviewers = join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} $this->getReviewers());
  my $numReviews = $this->numReviews();
  my $numComments = $this->numComments();

  my $toNode;
  if ($numReviews) {
    my @reviews = $this->getReviews();
    my $to = $reviews[0]->prop("to");
    $toNode = $this->getNet->getNode($to);
  }
  my $to = $toNode ? $toNode->prop("id") : "";
  my $toTitle = $toNode ? $this->translate($toNode->prop("title")) : "";

  my $action = $this->expandValue($this->prop("reviewAction") || $this->prop("previousAction"));
  my $nextEdge = $this->getNet->getEdge($node, $action, $toNode) || $this->getCurrentEdge();
  my $actionTitle = $nextEdge ? $this->translate($this->expandValue($nextEdge->prop("title"))) : "";
  my $class = $node->prop("class") || 'foswikiAlt';

  $result =~ s/\$web\b/$this->{_web}/g;
  $result =~ s/\$topic\b/$this->{_topic}/g;
  $result =~ s/\$roles\b/$roles/g;
  $result =~ s/\$rev\b/$this->{_rev}/g;
  $result =~ s#\$(approved|approval)Rev\b#$this->prop("approvalRev") // ($this->getLastApproved ?$this->getLastApproved->getRevision():'')#ge;
  $result =~ s/\$approvalTime\b/$this->getLastApproved ?$this->getLastApproved->prop("date"):''/ge;
  $result =~ s/\$approvalDuration\b/$this->getLastApproved ? time() - $this->getLastApproved->prop("date") : ''/ge;
  $result =~ s/\$approval(ID|State)?\b/$approvalID/gi;
  $result =~ s/\$approvalIDs\b/$approvalIDs/gi;
  $result =~ s/\$defaultNode\b/$defaultID/g;
  $result =~ s/\$admin(ID|Role)?\b/$adminID/gi;
  $result =~ s/\$actions\b/$actions/g;
  $result =~ s/\$edges\b/$edges/g;
  $result =~ s/\$nodes\b/$nodes/g;
  $result =~ s/\$numActions\b/$numActions/g;
  $result =~ s/\$numEdges\b/$numEdges/g;
  $result =~ s/\$numReviews\b/$numReviews/g;
  $result =~ s/\$numComments\b/$numComments/g;
  $result =~ s/\$notify\b/$notify/g;
  $result =~ s/\$emails\b/$emails/g;
  $result =~ s/\$hasPending\b/$hasPending/g;
  $result =~ s/\$pendingReviewers\b/$pendingReviewers/g;
  $result =~ s/\$epoch\b/$date/g; 
  $result =~ s/\$date\b/\$formatTime($date)/g; #
  $result =~ s/\$datetime\b/\$formatDateTime($date)/g; 
  $result =~ s/\$duration\b/$duration/g; 
  $result =~ s/\$previousState\b/$previousState/g; 
  $result =~ s/\$hasComments?\b/$hasComments/g;
  $result =~ s/\$comment\b/$comment/g;
  $result =~ s/\$comments\b/$comments/g;
  $result =~ s/\$reviewers\b/$reviewers/g;
  $result =~ s/\$actionTitle\b/$actionTitle/g;
  $result =~ s/\$action\b/$action/g;
  $result =~ s/\$signOff\b/floor($this->getCurrentSignOff()*100)/ge;
  $result =~ s/\$possibleReviewers(?:\((.*?)\))?/join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} $this->getPossibleReviewers(undef, undef, $1))/ge;
  $result =~ s/\$isParallel\b/$isParallel/g;
  $result =~ s/\$isAdmin\b/$adminRole?($adminRole->isMember($1)?1:0):""/ge;
  $result =~ s/\$state\b/$this->{id}/g; # alias
  $result =~ s/\$to\b/$to/g;
  $result =~ s/\$toTitle\b/$toTitle/g;
  $result =~ s/\$json\b/$json/g;
  $result =~ s/\$class\b/$class/g;

  if ($result =~ /\$reviews\b/) {
    my $reviews = $this->renderReviews($params);
    $result =~ s/\$reviews\b/$reviews/g;
  }

  $result =~ s/\$($stateRegex)\b/$this->expandValue($this->prop($1))/ge;

  # node props
  $result = $this->expandValue($node->render($result));

  return $result;
}


=begin TML

---++ ObjectMethod asJson() -> $json

TODO

=cut

sub asJson {
  my ($this, $params) = @_;

  my $json = {
    node => {},
    edges => []
  };

  my $node = $this->getCurrentNode();
  $json->{node} = $node->asJson() if $node;
  $json->{edges} = [map {$_->asJson()} grep {$_->prop("action") ne "_hidden_"} $this->getPossibleEdges($node)];
 
  return $json;
}

=begin TML

---++ ObjectMethod renderReviews() -> $string

returns a string representation of all reviews of a state

=cut

sub renderReviews {
  my ($this, $params) = @_;

  my $header = $params->{reviewheader};
  my $format = $params->{reviewformat};
  my $separator = $params->{reviewseparator};
  my $footer = $params->{reviewfooter};
  my $skip = $params->{reviewskip} || 0;
  my $limit = $params->{reviewlimit} || 0;
  my $reverse = Foswiki::Func::isTrue($params->{reviewreverse}, 0);

  unless (defined $header || defined $format || defined $separator || defined $footer) {
    $header = Foswiki::Func::expandTemplate("qm::review::header");
    $format = Foswiki::Func::expandTemplate("qm::review::format");
    $footer = Foswiki::Func::expandTemplate("qm::review::footer");
    $separator = Foswiki::Func::expandTemplate("qm::review::separator");
  }

  $header //= '';
  $footer //= '';
  $format //= '';
  $separator //= '';

  my @reviews = $this->getReviews();
  @reviews = reverse @reviews if $reverse;

  my $numReviews = scalar(@reviews);
  my $isFirst = 1;
  my $isLast = 0;
  my $i = 1;
  my @result = ();
  my $index = 0;

  foreach my $review (@reviews) {
    $isLast = 1 if $i == $numReviews;
    next unless $review->prop("comment");
    $index++;
    next if $skip && $index <= $skip;
    last if $limit && $index > $limit;

    my $line = $review->render($format);
    $line =~ s/\$isFirst\b/$isFirst/g;
    $line =~ s/\$isLast\b/$isLast/g;
    $line =~ s/\$index\b/$index/g;
    $line =~ s/\$comment\b//g;
    $isFirst = 0;

    push @result, $line if $line ne "";
    $i++;
  }
  return "" unless @result;

  my $result = $header.join($separator, @result).$footer;

  $result =~ s/\$count\b/scalar(@result)/ge;

  return $result;
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

---++ ObjectMethod translate($string) -> $string

translates a string using MultiLingualPlugin

=cut

sub translate {
  my ($this, $string) = @_;

  return Foswiki::Plugins::MultiLingualPlugin::translate($string, $this->getWeb, $this->getTopic);
}

=begin TML

---++ ObjectMethod stringify() -> $string

returns a string representation of this object

=cut

sub stringify {
  my $this = shift;

  my @result = ();
  push @result, "web=$this->{_web}", "topic=$this->{_topic}", "rev=$this->{_rev}";
  foreach my $key ($this->props) {
    push @result, "$key=" . ($this->prop($key)//'undef');
  }

  return join(", ", @result);
}

=begin TML

---++ ObjectMethod json()

returns a JSON encoder/decoder

=cut

sub json {
  my $this = shift;

  $this->{_json} //= JSON->new();

  return $this->{_json};
}

### statics

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::State - $_[0]\n";
}

sub _entityDecode {
  my $text = shift;

  if (defined $text) {
    $text =~ s/&#(\d+);/chr($1)/ge;
  }

  return $text;
}

1;
