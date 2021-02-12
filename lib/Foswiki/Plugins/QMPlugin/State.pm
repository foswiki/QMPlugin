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
use Assert;
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

  $this->{_web} = $web;
  $this->{_topic} = $topic;
  $this->{_meta} = $meta;
  $this->{_reviewCounter} = 0;

  ($this->{_meta}) = Foswiki::Func::readTopic($web, $topic, $rev)
    unless defined $this->{_meta};

  $this->{_rev} = $this->{_meta}->getLoadedRev() || 1;

  _writeDebug("init $web.$topic, rev=$this->{_rev} for state $this");

  my $qmData = $this->{_meta}->get("QMSTATE");

  unless ($qmData) {
    _writeDebug("no qmdata found");

    if (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
      _writeDebug("WorkflowPlugin is still enabled ... not migrating data");
    } else {
      # try to init from legacy WORKFLOW data
      my $legacyData = $this->{_meta}->get("WORKFLOW");

      if ($legacyData) {
        my $legacyHistory = $this->{_meta}->get("WORKFLOWHISTORY", $legacyData->{"LASTVERSION_".$legacyData->{name}});

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
        #_writeDebug("no legacy found");
      }
    }
  }

  $qmData ||= {};

  # init from topicinfo
  my $info = $this->{_meta}->getRevisionInfo();
  $qmData->{author} //= $info->{author};
  $qmData->{date} //= $info->{date};
  $qmData->{changed} //= 0;

  # init from qmstate and qmworkflow formfields
  my ($fieldDef, $field) = $this->getCore->getQMStateFormfield($this->{_meta});
  if ($fieldDef) {
    my $workflow = $fieldDef->param("workflow");
    $qmData->{workflow} = $workflow if defined $workflow && $workflow ne '';
    $qmData->{id} = $field->{value} if defined $field->{value} && $field->{value} ne '';
  }
  my $workflowField = $this->getCore->getQMWorkflowFormfield($this->{_meta});
  $qmData->{workflow} = $workflowField->{value} if defined $workflowField;

  while (my ($key, $val) = each %$qmData) {
    next if $key =~ /^_/;
    #_writeDebug("key=$key, val=$val");
    $this->{$key} = $val;
  }

  $this->setWorkflow();

  $this->{_reviews} = [];
  foreach my $reviewData ($this->{_meta}->find("QMREVIEW")) {
    push @{$this->{_reviews}}, Foswiki::Plugins::QMPlugin::Review->new($this, $reviewData);
  };

  # SMELL: no legacy comments are preserved
  
  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  #_writeDebug("finishing state $this");

  $this->{_net}->finish() if defined $this->{_net};

  foreach my $review ($this->getReviews()) {
    $review->finish;
  }

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

  _writeDebug("called setWorkflow($workflow)");

  my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($this->{_web}, $workflow);
  $web =~ s/\//./g;

  $this->{_gotChange} = 1 if $oldWorkflow ne "$web.$topic";


  if ($oldWorkflow ne "$web.$topic" || !$this->{_net}) {
    $this->{workflow} = "$web.$topic";

    #_writeDebug("reloading net");
    $this->{_net}->finish() if defined $this->{_net};
    $this->{_net} = Foswiki::Plugins::QMPlugin::Net->new($web, $topic, $this);

    print STDERR "WARNING: cannot create a net for workflow $web.$topic\n" unless defined $this->{_net};

    $this->{id} ||= $this->{_net}->getDefaultNode->prop("id") if defined $this->{_net};
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

  my @result = sort keys %props;
  return @result;
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
      $this->{_gotChange} = 1;
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
  $this->{_gotChange} = 1 if defined $val;

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
    my $origVal = $val;
    Foswiki::Func::pushTopicContext($this->{_web}, $this->{_topic});
    $val = Foswiki::Func::expandCommonVariables($val, $this->{_topic}, $this->{_web}, $this->{_meta});
    Foswiki::Func::popTopicContext();

    #_writeDebug("expandVal($origVal) = $val");
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

  $this->{_saveInProgress} = 1;
  $this->processCommands("beforeSave");

  $args{forcenewrevision} = 1 if $this->{_migrateFromLegacy} || $this->prop("changed") ne $this->hasChanged();
  undef $this->{_migrateFromLegacy};

  $this->updateMeta();
  $this->setACLs();

  _writeDebug("save $this->{_web}.$this->{_topic}");

  $this->getCore->saveMeta($this->{_meta}, %args);
  $this->processCommands("afterSave");

  $this->{_saveInProgress} = 0;

  return $this;
}

=begin TML

---++ ObjectMethod updateMeta() -> $this

save this state into the assigned meta object, don't save it to the store actually

=cut

sub updateMeta {
  my $this = shift;

  _writeDebug("updateMeta ");

  my $hasChanged = $this->hasChanged();
  my $oldData = $this->{_meta}->get("QMSTATE");

  my $net = $this->getNet();
  if (defined $net && defined $this->{workflow} && $this->{workflow} ne '') {
    _writeDebug("setting state");

    # set props before saving
    $this->{date} = time;
    $this->{author} = Foswiki::Func::getWikiName();
    $this->{id} ||= $net->getDefaultNode->prop("id");
    $this->prop("changed", $this->hasChanged());

    # test for changes
    my %data = ();
    foreach my $key ($this->props) {
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
      _writeDebug("... qmstate change");
      $this->{_meta}->remove("QMSTATE");
      $this->{_meta}->remove("QMREVIEW");

      unless (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
        $this->{_meta}->remove("WORKFLOW");
        $this->{_meta}->remove("WORKFLOWHISTORY");
      }

      # store QMSTATE
      $this->{_meta}->put("QMSTATE", \%data);

      # store QMREVIEWs
      foreach my $review ($this->getReviews()) {
        $review->store($this->{_meta});
      }

      # sync qmstate formfield
      my $qmStateField = $this->getCore->getQMStateFormfield($this->getMeta());
      if ($qmStateField) {
        _writeDebug("... found qmstate field $qmStateField->{name}, setting value from $qmStateField->{value} to $this->{id}");
        $qmStateField->{value} = $this->{id};
      }
    } else {
      _writeDebug("... qmstate did not change");
    }

  } else {
    _writeDebug("deleting state"); 

    $this->{_meta}->remove("QMSTATE");
    $this->{_meta}->remove("QMREVIEW");

    unless (Foswiki::Func::getContext()->{WorkflowPluginEnabled}) {
      $this->{_meta}->remove("WORKFLOW");
      $this->{_meta}->remove("WORKFLOWHISTORY");
    }
  }

  return $this;
}

=begin TML

---++ ObjectMethod change($action, $to, $comment, $user) -> $boolean

change this state by performing a certain action, providing an optional comment;
returns true if the action was successfull and the state has been transitioned along the lines
of the net. Otherwise an error is thrown. Note that only the properties of this state
are changed; it is _not_ stored into the current topic; you must call the =save()= method
to do so.

=cut

sub change {
  my ($this, $action, $to, $comment, $user) = @_;

  _writeDebug("change state $action, $to");

  my $node = $this->getCurrentNode();
  throw Error::Simple("Woops, current node is invalid.") unless defined $node;

  $user //= $this->getCore->getSelf();
  my $wikiName = $user->prop("wikiName");

  foreach my $edge ($this->getPossibleEdges()) {
    next unless $action eq $edge->prop("action") && $to eq $edge->prop("to");

    # check review progress
    $this->filterReviews($action);

    # check reviewer
    throw Error::Simple("$wikiName already reviewed current state.")
      if $this->isParallel && $this->isReviewedBy($user);

    my $review = $this->addReview({
        "from" => $this->{id},
        "action" => $action,
        "to" => $to,
        "author" => $wikiName,
        "comment" => $comment,
      }
    );

    $this->{_gotChange} = 1;

    # check signoff
    my $minSignOff = $edge->getSignOff();
    my $signOff = $this->getCurrentSignOff($edge);

    # set signoff if required
    $review->prop("signOff", $signOff) if $minSignOff;

    _writeDebug("minSignOff=$minSignOff, signOff=$signOff");

    # traverse edge if signoff is reached
    if ($signOff >= $minSignOff) {
      $this->traverse($edge);
    } else {
      _writeDebug("not yet switching to next node");
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

  _writeDebug("filterReviews not matching id=$id, action=$action");

  my $hasChanged = 0;
  my @reviews = ();

  foreach my $review (@{$this->{_reviews}}) {

    if ($review->prop("from") eq $id && $review->prop("action") eq $action) {
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

---++ ObjectMethod traverse($edge) 

change the current state by traversing the given edge;
note that this only changes the current location within the net; the changed data is _not_ stored
into the current state.

=cut

sub traverse {
  my ($this, $edge) = @_;

  my $fromNode = $edge->fromNode();
  my $toNode = $edge->toNode();
  my $command = $edge->prop("command");

  _writeDebug("traverse from ".$fromNode->prop("id")." to ".$toNode->prop("id")." via action ".$edge->prop("action").($command?" executing $command":""));

  $this->{previousNode} = $fromNode->prop("id"); 
  $this->{previousAction} = $edge->prop("action");
  $this->{id} = $toNode->prop("id");

  # execute all commands
  $edge->execute();

  # queue internal notify command about new state; will be processed after save
  $this->queueCommand($edge, "notify");
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
    push @{$this->{_queue}{$handler->{type}}}, Foswiki::Plugins::QMPlugin::Command->new($handler, $edge, $params);
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
    $command->execute();
  }

  # clear queue
  $this->{_queue}{$type} = ();
}

=begin TML

---++ ObjectMethod sendNotification($template) -> $errors

send email notifications for the current edge transition. this is called when a transition
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

  my $emails = $edge->getEmails();
  if ($emails) {
    _writeDebug("... emails=$emails");
  } else {
    _writeDebug("... no emails found in edge: ".$edge->stringify) if TRACE;
    return;
  }

  $template ||= "qmpluginnotify";
  Foswiki::Func::readTemplate($template);

  my $id = $this->expandValue($edge->prop("to"));
  my $tmpl = Foswiki::Func::expandTemplate("qm::notify::$id") || Foswiki::Func::expandTemplate("qm::notify");

  _writeDebug("...woops, empty template") unless $tmpl;
  return unless $tmpl;

  my $text = $this->expandValue($tmpl);

  $text =~ s/^\s+//g;
  $text =~ s/\s+$//g;

  _writeDebug("...email text=$text");

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

  _writeDebug("... no current node") unless defined $node;

  unless (defined $node) {

    # nuke all existing acls
    foreach my $key (qw(ALLOWTOPICCHANGE 
                        ALLOWTOPICVIEW 
                        ALLOWTOPICAPPROVE
                        PERMSET_CHANGE 
                        PERMSET_CHANGE_DETAILS 
                        PERMSET_VIEW 
                        PERMSET_VIEW_DETAILS)) {
      $this->{_meta}->remove('PREFERENCE', $key);
    }

    return 0;
  }

  my $oldAllowView = $this->{_meta}->get("PREFERENCE", "ALLOWTOPICVIEW");
  my $oldAllowEdit = $this->{_meta}->get("PREFERENCE", "ALLOWTOPICCHANGE");
  my $oldAllowApprove = $this->{_meta}->get("PREFERENCE", "ALLOWTOPICAPPROVE");

  $oldAllowView = $oldAllowView ? join(", ", sort split(/\s*,\s*/, $oldAllowView->{value})) : "";
  $oldAllowEdit = $oldAllowEdit ? join(", ", sort split(/\s*,\s*/, $oldAllowEdit->{value})) : "";
  $oldAllowApprove = $oldAllowApprove ? join(", ", sort split(/\s*,\s*/, $oldAllowApprove->{value})) : "";

  _writeDebug("... old allow view : $oldAllowView");
  _writeDebug("... old allow change : $oldAllowEdit");
  _writeDebug("... old allow approve : $oldAllowApprove");

  #_writeDebug("... node=".$node->stringify);

  my @allowEdit = $node->getACL("allowEdit");
  _writeDebug("... new allow change: @allowEdit");

  my $allowEdit = join(", ", @allowEdit);
  if ($allowEdit ne $oldAllowEdit) {
    _writeDebug("... setting allowEdit to $allowEdit");

    $this->{_meta}->remove("PREFERENCE", "ALLOWTOPICCHANGE");
    $this->{_meta}->remove("PREFERENCE", "PERMSET_CHANGE");
    $this->{_meta}->remove("PREFERENCE", "PERMSET_CHANGE_DETAILS");

    if (@allowEdit) {
      $this->{_meta}->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICCHANGE',
        title => 'ALLOWTOPICCHANGE',
        value => $allowEdit,
        type  => 'Set'
      });
    }
    $hasChanged = 1;
  } else {
    _writeDebug("... allowEdit did not change");
  }

  my @allowView = $node->getACL("allowView");
  _writeDebug("... new allow view: @allowView");

  my $allowView = join(", ", @allowView);
  if ($allowView ne $oldAllowView) {
    _writeDebug("... setting allowView to @allowView");

    $this->{_meta}->remove("PREFERENCE", "ALLOWTOPICVIEW");
    $this->{_meta}->remove("PREFERENCE", "PERMSET_VIEW");
    $this->{_meta}->remove("PREFERENCE", "PERMSET_VIEW_DETAILS");

    if (@allowView) {
      $this->{_meta}->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICVIEW',
        title => 'ALLOWTOPICVIEW',
        value => join(", ", sort @allowView),
        type  => 'Set'
      });
    }
    $hasChanged = 1;
  } else {
    _writeDebug("... allowView did not change");
  }

  my @allowApprove = $this->getPossibleReviewers();
  my $allowApprove = join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} @allowApprove);

  if ($allowApprove ne $oldAllowApprove) {

    $this->{_meta}->remove("PREFERENCE", "ALLOWTOPICAPPROVE");

    if (@allowApprove) {
      _writeDebug("... setting new allowApprove to $allowApprove");
      $this->{_meta}->putKeyed('PREFERENCE', {
        name  => 'ALLOWTOPICAPPROVE',
        title => 'ALLOWTOPICAPPROVE',
        value => $allowApprove,
        type  => 'Set'
      });
    }

    $hasChanged = 1;
  } else {
    _writeDebug("... allowApprove did not change");
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

---++ ObjectMethod getLAstApproved() -> $state

get the state that was last approved starting at the current rev

=cut

sub getLastApproved {
  my $this = shift;

  my $net = $this->getNet();
  return unless $net;

  my $state = $this->{_lastApproved};
  return $state if $state;

  my $node = $net->getApprovalNode();
  return unless $node;

  my $approvalID = $node->prop("id");

  for (my $i = $this->{_rev}; $i > 0; $i--) {
    my $s = $this->getCore->getState($this->{_web}, $this->{_topic}, $i);
    next unless $s && $s->prop("id");
    next unless $s->prop("changed") || $i == 1;
    next unless $approvalID eq $s->prop("id");

    $state = $s;
    last;
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

  my $edge = $net->getEdge($this->{previousNode}, $action);
  return unless defined $edge;

  return $edge;
}


=begin TML

---++ ObjectMethod getNet() -> $net

get the net that this state is currently associated with

=cut

sub getNet {
  my $this = shift;

  return $this->{_net};
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

  my @edges = ();

  unless ($this->isParallel() && $this->isReviewedBy($user)) {
    $node //= $this->getCurrentNode();

    if (defined $node) {
      foreach my $edge ($node->getOutgoingEdges()) {
        push @edges, $edge if $edge->isEnabled($user);
      }
    }
  }

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
  
  if (defined $node) {

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

  if ($this->{_reviews}) {
    foreach my $review ($this->getReviews()) {
      return $review->prop("from") eq $this->{id} && (
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

---++ ObjectMethod hasChanged() -> $boolean

returns true when this state was changed as part of a transition, returns false if other
changes happened to the topic

=cut

sub hasChanged {
  my $this = shift;

  return $this->{_gotChange} ? 1:0;
}

=begin TML

---++ ObjectMethod getCurrentSignOff($edge) -> $percent

get the current sign-off progress in percent that the given
edge has already been approved by reviewers

=cut

sub getCurrentSignOff {
  my ($this, $edge) = @_;

  #_writeDebug("getCurrentSignOff");
  $edge ||= $this->getReviewEdge();
  return 0 unless defined $edge;

  #_writeDebug("edge: ".$edge->stringify);

  my @reviewers = $this->getReviewers($edge->prop("action"));
  #_writeDebug("reviewers=@reviewers");
  return 0 unless @reviewers;

  my @allowed = $edge->getReviewers;
  #_writeDebug("allowed=@allowed");
  return 1 unless @allowed;

  my $signOff =  scalar(@reviewers) / scalar(@allowed);
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

---++ ObjectMethod getcomments() -> @comments

get the list of comments in reviews

=cut

sub getComments {
  my $this = shift;

  my @comments = ();

  foreach my $review ($this->getReviews()) {
    my $comment = $review->prop("comment");
    push @comments, $comment if defined($comment) && $comment ne "";
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

  my $approval = $this->getNet->getApprovalNode();
  my @possibleApprovers = $this->getPossibleReviewers($node, undef, $approval);

  return @possibleApprovers;
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

---++ ObjectMethod render($format) -> $string

render the properties of this object given the specified format string 

=cut

sub render {
  my ($this, $format, $params) = @_;

  my $net = $this->getNet();
  return "" unless defined $net;

  my $defaultNode = $net->getDefaultNode;
  my $defaultID = $defaultNode->prop("id");

  my $approval = $net->getApprovalNode;
  my $approvalID = $approval?$approval->prop("id"):'';

  my $adminRole = $net->getAdminRole;
  my $adminID = $adminRole?$adminRole->prop("id"):'';

  my $node = $this->getCurrentNode();
  return "" unless defined $node;
  #_writeDebug("node=".join(",", $node->props));

  my $result = $format || '';

  my $edge = $this->getCurrentEdge();
  my $notify = "";
  my $emails = "";
  if ($result =~ /\$notify\b/) {
    $notify = $edge ? join(", ", sort map {$_->prop("id")} $edge->getNotify()):"";
  }
  if ($result =~ /\$emails\b/) {
    $emails = $edge?join(", ", sort $edge->getEmails()):"";
  }
  my $edgeTitle = $edge ? $edge->prop("title") : "";

  my $numActions = 0;
  my $actions = "";
  if ($result =~ /\$(actions|numActions)\b/) {
    my @actions = sort $this->getPossibleActions();
    $actions = join(", ", @actions);
    $numActions = scalar(@actions);
  }

  my $numEdges = 0;
  my $edges = "";
  if ($result =~ /\$(edges|numEdges)\b/) {
    my @edges = sort {$a->index <=> $b->index} $this->getPossibleEdges();
    $edges = join(", ", map {$_->prop("from") . "/" . $_->prop("action"). "/" . $_->prop("to")} @edges);
    $numEdges = scalar(@edges);
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

  my @comments = $this->getComments();
  my $comments = join(", ", @comments);
  my $hasComments = scalar(@comments)?1:0;
  my $reviewers = join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} $this->getReviewers());
  my $numReviews = $this->numReviews();
  my $numComments = $this->numComments();

  $result =~ s/\$web\b/$this->{_web}/g;
  $result =~ s/\$topic\b/$this->{_topic}/g;
  $result =~ s/\$roles\b/$roles/g;
  $result =~ s/\$rev\b/$this->{_rev}/g;
  $result =~ s/\$(approved|approval)Rev\b/$this->getLastApproved()?$this->getLastApproved->getRevision():''/ge;
  $result =~ s/\$approvalTime\b/$this->getLastApproved()?$this->getLastApproved->prop("date"):''/ge;
  $result =~ s/\$approvalDuration\b/$this->getLastApproved()?time() - $this->getLastApproved->prop("date"):''/ge;
  $result =~ s/\$approval(ID|State)?\b/$approvalID/gi;
  $result =~ s/\$defaultNode\b/$defaultID/g;
  $result =~ s/\$admin(ID|Role)?\b/$adminID/gi;
  $result =~ s/\$actions\b/$actions/g;
  $result =~ s/\$edges\b/$edges/g;
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
  $result =~ s/\$comments?\b/$comments/g;
  $result =~ s/\$reviewers\b/$reviewers/g;
  $result =~ s/\$action\b/$this->expandValue($this->prop("reviewAction") || $this->prop("previousAction"))/ge;
  $result =~ s/\$actionTitle\b/$this->expandValue($edgeTitle)/ge;
  $result =~ s/\$signOff\b/floor($this->getCurrentSignOff()*100)/ge;
  $result =~ s/\$possibleReviewers(?:\((.*?)\))?/join(", ", sort map {$_->prop("wikiName") || $_->prop("id")} $this->getPossibleReviewers(undef, undef, $1))/ge;
  $result =~ s/\$isParallel\b/$isParallel/g;
  $result =~ s/\$isAdmin\b/$adminRole?($adminRole->isMember($1)?1:0):""/ge;
  $result =~ s/\$state\b/$this->{id}/g; # alias

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
