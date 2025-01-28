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

package Foswiki::Plugins::QMPlugin::Core;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Core

core class for this plugin

an singleton instance is allocated on demand

=cut

use strict;
use warnings;

use Assert;
use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Form ();
use Foswiki::Attrs ();
use Foswiki::Plugins ();
use Foswiki::Plugins::QMPlugin::Net ();
use Foswiki::Plugins::QMPlugin::TopicIterator ();
use Foswiki::Plugins::QMPlugin::State ();
use Foswiki::Plugins::QMPlugin::User ();
use Foswiki::Plugins::QMPlugin::Group ();
use Foswiki::Contrib::JsonRpcContrib::Error ();

=begin TML

---++ =ClassProperty= TRACE

boolean toggle to enable debugging of this class

=cut

use constant TRACE => 0;    # toggle me

=begin TML

---++ =ClassProperty= @defaultHandler

list of default handlers 

=cut

our @defaultHandler = ({
    id => 'notify',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Notify',
    function => 'afterSaveHandler',
    type => 'afterSave',
  },
  {
    id => 'fork',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Fork',
    function => 'beforeSaveHandler',
    type => 'beforeSave',
  },
  {
    id => 'fork',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Fork',
    function => 'afterSaveHandler',
    type => 'afterSave',
  },
  {
    id => 'copy',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Copy',
    function => 'handle',
    type => 'afterSave',
  },
  {
    id => 'move',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Move',
    function => 'handle',
    type => 'afterSave',
  },
  {
    id => 'trash',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Trash',
    function => 'handle',
    type => 'afterSave',
  },
  {
    id => 'merge',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Merge',
    function => 'handle',
    type => 'afterSave',
  },
  {
    id => 'pref',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Pref',
    function => 'handle',
    type => 'beforeSave',
  },
  {
    id => 'formfield',
    package => 'Foswiki::Plugins::QMPlugin::Handler::Formfield',
    function => 'handle',
    type => 'beforeSave',
  },
  {
    id => 'deleteMeta',
    package => 'Foswiki::Plugins::QMPlugin::Handler::DeleteMeta',
    function => 'handle',
    type => 'beforeSave',
  },
  {
    id => 'createTopic',
    package => 'Foswiki::Plugins::QMPlugin::Handler::CreateTopic',
    function => 'handle',
    type => 'afterSave',
  },
);

=begin TML

---++ ClassMethod new() -> $core

constructor for a Core object

=cut

sub new {
  my $class = shift;

  my $this = bless({@_}, $class);

  $this->{_states} = ();
  $this->{_nets} = ();
  $this->{_commandHandler} = {};
  $this->{_saveInProgress} = 0;
  $this->{_redirectUrl} = undef;

  # make sure the qmplugin template is loaded
  if (Foswiki::Func::expandTemplate("qm::state") eq "") {
    Foswiki::Func::readTemplate("qmplugin");
  }

  # register default handler
  foreach my $handler (@defaultHandler) {
    $this->registerCommandHandler($handler);
  }

  return $this;
}

=begin TML

---++ ObjectMethod finish()

called when this object is destroyed

=cut

sub finish {
  my $this = shift;

  foreach my $state (values %{$this->{_states}}) {
    $state->finish if ref($state);
  }

  foreach my $net (values %{$this->{_nets}}) {
    $net->finish if ref($net);
  }

  undef $this->{_commandHandler};
  undef $this->{_nets};
  undef $this->{_states};
  undef $this->{_users};
  undef $this->{_users_index};
  undef $this->{_groups};
  undef $this->{_groups_index};
  undef $this->{_redirectUrl};
}

=begin TML

---++ ObjectMethod getUsers() -> @users

get the list of all users known to the core up to this point

=cut

sub getUsers {
  my $this = shift;

  return values %{$this->{_users}};
}

=begin TML

---++ ObjectMethod getUser($id) -> $user

get a user of a specific id

=cut

sub getUser {
  my ($this, $id) = @_;

  $id //= Foswiki::Func::getWikiName();

  my $user = $this->{_users_index}{$id};

  unless (defined $user) {
    $user = Foswiki::Plugins::QMPlugin::User->new($id);
    if (defined $user) {

      my $cuid = $user->prop("id"); 
      $this->{_users}{$cuid} = $this->{_users_index}{$cuid} = $user;

      my $wikiName = $user->prop("wikiName");
      $this->{_users_index}{$wikiName} = $user if $wikiName;

      my $userName = $user->prop("userName");
      $this->{_users_index}{$userName} = $user if $userName;

      my $email = $user->prop("email");
      $this->{_users_index}{$user->prop("email")} = $user if $email;
    }
  }

  return $user;
}

=begin TML

---++ ObjectMethod getSelf() -> $user

get the user for the currently logged in user

=cut

sub getSelf {
  my $this = shift;

  return $this->getUser();
}

=begin TML

---++ ObjectMethod getGroups() -> @groups

get the list of all groups known to the core up to this point

=cut

sub getGroups {
  my $this = shift;

  return values %{$this->{_groups}};
}

=begin TML

---++ ObjectMethod getGroup($id) -> $group

get a group of a specific id

=cut

sub getGroup {
  my ($this, $id) = @_;

  return unless $id;

#my ($package, $file, $line) = caller;
#print STDERR "called getGroup($id) by $package, line $line\n";
  
  my $group = $this->{_groups_index}{$id};

  unless (defined $group) {
    $group = Foswiki::Plugins::QMPlugin::Group->new($id);
    if ($group) {

      $id = $group->prop("id");
      $this->{_groups}{$id} = $this->{_groups_index}{$id} = $group;

      my $wikiName = $group->prop("wikiName");
      $this->{_groups_index}{$wikiName} = $group if $wikiName;
    }
  }

  return $group;
}


=begin TML

---++ ObjectMethod saveMeta($meta)

save a meta by suppressing the beforeSaveHandler

=cut

sub saveMeta {
  my $this = shift;
  my $meta = shift;

  _writeDebug("called saveMeta(".$meta->getPath().")");

  $this->{_saveInProgress} = 1;
  my $rev = $meta->save(@_);
  $this->{_saveInProgress} = 0;

  return $rev;
}

=begin TML

---++ ObjectMethod afterSaveHandler($web, $topic, $meta)

make sure the saved topic has got the right access control settings

=cut

sub afterSaveHandler {
  my ($this, $web, $topic, $meta) = @_;

  return if $this->{_saveInProgress};
  _writeDebug("called afterSaveHandler for $web.$topic, $meta");

  my $state = $this->getState($web, $topic, undef, $meta, 1);
  unless (defined $state) {
    _writeDebug("no qmstate found");
    return;
  }

  my $workflow = $state->prop("workflow");
  unless (defined $workflow) {
    _writeDebug("no workflow found");
    return;
  }

  my $hasChanged = $state->setACLs();
  unless ($hasChanged) {
    _writeDebug("acls didn't change");
    return;
  }

  _writeDebug("saving new acls");
  $this->saveMeta($meta,
# DON'T change the save flags as this overrides those done by the user
#    minor => 1,
#    dontlog => 1
  );

  if (TRACE) {
    my $allowView = $meta->get("PREFERENCE", "ALLOWTOPICVIEW");
    my $allowEdit = $meta->get("PREFERENCE", "ALLOWTOPICCHANGE");
    my $allowApproval = $meta->get("PREFERENCE", "ALLOWTOPICAPPROVE");
    print STDERR "allowView=" . ($allowView ? $allowView->{value} : 'undef') . "\n";
    print STDERR "allowEdit=" . ($allowEdit ? $allowEdit->{value} : 'undef') . "\n";
    print STDERR "allowApprove=" . ($allowApproval ? $allowApproval->{value} : 'undef') . "\n";
  }

  _writeDebug("done afterSaveHandler");
}

=begin TML

---++ ObjectMethod beforeSaveHandler($web, $topic, $meta)

   * make sure the saved topic has got the right workflow
   * trigger a state change when a qmstate formfield has been altered

=cut

sub beforeSaveHandler {
  my ($this, $web, $topic, $meta) = @_;

  return if $this->{_saveInProgress};
  _writeDebug("called beforeSaveHandler for $web.$topic, $meta");

  ($meta) = Foswiki::Func::readTopic($web, $topic) unless defined $meta;

  my $state = $this->getState($web, $topic, undef, $meta);
  _writeDebug("no qmstate found") unless defined $state;
  return unless defined $state;

  ### 1. get workflow from request
  my $request = Foswiki::Func::getRequestObject();
  my $doUnsetWorkflow = 0;

  my $workflow = $request->param("workflow");
  if (defined $workflow) {
    if ($workflow eq "") {
      _writeDebug("removing workflow as reuqested");
      $doUnsetWorkflow = 1;
    } else {
      _writeDebug("found workflow in reuqest");
    }
  } else {
    # 2. get workflow from qmworkflow formfield
    my $workflowField = $this->getQMWorkflowFormfield($meta);

    if ($workflowField) {
      $workflow = $workflowField->{value};
      _writeDebug("found workflowField, name=$workflowField->{name}");
      $doUnsetWorkflow = 1 unless $workflow;
    }
  } 

  unless ($doUnsetWorkflow) {
    # 4. get workflow from text 
    unless ($workflow) {
      my $text = $meta->text() || '';
      while ($text =~ /%QMSTATE\{(.*?)\}%/gms) {
        my $params = Foswiki::Attrs->new($1);
        $workflow = $params->{workflow};

        if ($workflow) {
          my $thisTopic = $params->{_DEFAULT} || $params->{topic} || $topic;
          my $thisWeb = $web;

          ($thisWeb, $thisTopic) = Foswiki::Func::normalizeWebTopicName($thisWeb, $thisTopic);

          if ($thisWeb eq $web && $thisTopic) {
            $workflow = $params->{workflow};
            last;
          }
        }
      }
    }

    # 5. get workflow from qm meta data
    unless ($workflow) {
      $workflow = $state->prop("workflow");
      _writeDebug("found workflow in meta data") if $workflow;
    }
  }

  if ($workflow && !$doUnsetWorkflow) {
    _writeDebug("found workflow '$workflow'");

    _writeDebug("setting workflow");
    $state->setWorkflow($workflow);

  } else {
    if ($state->prop("workflow")) {
      _writeDebug("unsetting workflow");
      $state->unsetWorkflow();
      $state->updateMeta();
    }
  }

  if ($state->hasChanged()) {
    _writeDebug("state changed ... saving changes.");
    $state->save();
  } else {
    _writeDebug("no changes");
  }

  _writeDebug("done beforeSaveHandler");
}

=begin TML

---++ ObjectMethod getFormfieldDefinition($meta, $type) -> $fieldDef

returns a Foswiki::Form::FieldDefinition for the given formfield type.
this is used to return the definitions of a qmstate or qmworkflow formfield.

returns undef if the form doesn't have a formfield of the requested type

=cut

sub getFormfieldDefinition {
  my ($this, $meta, $type) = @_;

  my $topic = $meta->getFormName();
  return unless $topic;

  my $web = $meta->web();

  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
  return unless Foswiki::Func::topicExists($web, $topic);

  my $session = $Foswiki::Plugins::SESSION;

  my $form;
  try {
    $form = Foswiki::Form->new($session, $web, $topic);
  } catch Error::Simple with {
    print STDERR "ERROR: " . shift . "\n";
  };
  return unless $form;

  my $fields = $form->getFields();
  return unless $fields;

  foreach my $fieldDef (@$fields) {
    return $fieldDef if $fieldDef && $fieldDef->{type} && $fieldDef->{type} eq $type;
  }

  return;
}

=begin TML

---++ ObjectMethod getQMStateFormfield($meta) -> $field

return a formfield of a qmstate if it exists

=cut

sub getQMStateFormfield {
  my ($this, $meta) = @_;

  my $fieldDef = $this->getFormfieldDefinition($meta, "qmstate");
  return unless $fieldDef;

  my $field = $meta->get("FIELD", $fieldDef->{name});
  return wantarray ? ($fieldDef, $field) : $field;
}

=begin TML

---++ ObjectMethod getQMWorkflowFormfield($meta) -> $field

return a formfield of a qmworkflow if it exists

=cut

sub getQMWorkflowFormfield {
  my ($this, $meta) = @_;

  my $fieldDef = $this->getFormfieldDefinition($meta, "qmworkflow");
  return unless $fieldDef;

  my $field = $meta->get("FIELD", $fieldDef->{name});
  return wantarray ? ($fieldDef, $field) : $field;
}

=begin TML

---++ ObjectMethod jsonRpcCancelTransition($session, $request)

json-rpc handler for the =cancelTransition= procedure

=cut

sub jsonRpcCancelTransition {
  my ($this, $session, $request) = @_;

  my $wikiName = Foswiki::Func::getWikiName();
  my $web = $request->param("web") || $session->{webName};
  my $topic = $request->param("topic") || $session->{topicName};

  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(404, "Topic does not exist")
    unless Foswiki::Func::topicExists($web, $topic);

  _writeDebug("called jsonRpcCancelTransition(), topic=$web.$topic, wikiName=$wikiName");

  my ($meta) = Foswiki::Func::readTopic($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(401, "Access denied")
    unless Foswiki::Func::checkAccessPermission("APPROVE", $wikiName, undef, $topic, $web, $meta)
    || Foswiki::Func::checkAccessPermission("CHANGE", $wikiName, undef, $topic, $web, $meta);

  my $state = $this->getState($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(1002, "no qmstate found at $web.$topic")
    unless $state;

  my $hasChanged = $state->resetReviews;
  $state->save if $hasChanged;

  my $redirect = $request->param("redirect");

  return {redirect => $redirect} if defined $redirect;
  return 1;
}

=begin TML

---++ ObjectMethod jsonRpcChangeState($session, $request)

json-rpc handler for the =changeState= procedure

=cut

sub jsonRpcChangeState {
  my ($this, $session, $request) = @_;

  my $wikiName = Foswiki::Func::getWikiName();
  my $web = $request->param("web") || $session->{webName};
  my $topic = $request->param("topic") || $session->{topicName};
  my $comment = $request->param("comment");
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(404, "Topic does not exist")
    unless Foswiki::Func::topicExists($web, $topic);

  my $action = $request->param("action");
  throw Foswiki::Contrib::JsonRpcContrib::Error(1005, "action not defined")
    unless defined $action;

  my $to = $request->param("to");
  #throw Foswiki::Contrib::JsonRpcContrib::Error(1005, "to not defined")
  #  unless defined $to;

  _writeDebug("called jsonRpcChangeState(), topic=$web.$topic, wikiName=$wikiName, action=$action, to=".($to//'undef'));

  my ($meta) = Foswiki::Func::readTopic($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(401, "Access denied")
    unless Foswiki::Func::checkAccessPermission("APPROVE", $wikiName, undef, $topic, $web, $meta)
    || Foswiki::Func::checkAccessPermission("CHANGE", $wikiName, undef, $topic, $web, $meta);

  my $state = $this->getState($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(1002, "no qmstate found at $web.$topic")
    unless $state;

  my $workflowField = $this->getQMWorkflowFormfield($meta);
  my $workflow = $request->param("workflow") || ($workflowField && $workflowField->{value});
  $workflow //= $state->prop("workflow");
  $state->setWorkflow($workflow) if $workflow;

  my $error;
  my $hasChanged = 0;
  try {
    $hasChanged = $state->change($action, $to, $comment);
  } catch Error::Simple with {
    $error = shift->stringify;
    print STDERR "ERROR: $error\n";

    $error =~ s/ at .*$//s;
  };

  throw Foswiki::Contrib::JsonRpcContrib::Error(1006, $error)
    if defined $error;

  return 1 unless $hasChanged;

  try {
    $state->save(
      ignorepermissions => 1,
      forcenewrevision => 1
    );
  } catch Error with {
    $error = shift;
    print STDERR "ERROR: $error\n";
    throw Error::Simple("Sorry, there was an error when saving the state.");
  };

  return {redirect => $this->redirectUrl()} if defined $this->redirectUrl();
  return 1;
}

=begin TML

---++ ObjectMethod jsonRpcSendNotification($session, $request)

json-rpc handler for the =sendNotification= procedure

=cut

sub jsonRpcSendNotification {
  my ($this, $session, $request) = @_;

  my $wikiName = Foswiki::Func::getWikiName();
  my $web = $request->param("web") || $session->{webName};
  my $topic = $request->param("topic") || $session->{topicName};
  my $template = $request->param("template");
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  _writeDebug("called jsonRpcNotify(), topic=$web.$topic, wikiName=$wikiName");

  throw Foswiki::Contrib::JsonRpcContrib::Error(404, "Topic does not exist")
    unless Foswiki::Func::topicExists($web, $topic);

  my ($meta) = Foswiki::Func::readTopic($web, $topic);

  my $state = $this->getState($web, $topic);

  throw Foswiki::Contrib::JsonRpcContrib::Error(1002, "no qmstate found at $web.$topic")
    unless $state;

  try {
    $state->sendNotification($template);
  } catch Error with {
    my $e = shift;
    print STDERR "ERROR: sending notifification - " .$e."\n";
    throw Foswiki::Contrib::JsonRpcContrib::Error(1001, $e->stringify())
  };

  return 1;
}

=begin TML

---++ ObjectMethod restTriggerStates($session)

this handler searches for topics with a workflow attached to it and triggers
any automatic transition found. Parameters

   * webs: list of webs to search for controlled topics, defaults to all webs
   * includeweb: regular expression of webs to include into the process (default all)
   * excludeweb: regular expression of webs to exclude from the process (default none)
   * includetopic: regular expression of topics to include into the process (default all)
   * excludetopic: regular expression of topics to exclude from the process (default none)
   * includeworkflow: regular expression of workflows to process (default all)
   * excludeworkflow: regular expression of workflows to exclude from the process (default none)
   * dry: boolean switch to enable a "dry run" not changing anything (defaults to "off")

WARNING: this handler is typically called by a cronjob, from the commandline or by admins.

=cut

sub restTriggerStates {
  my ($this, $session) = @_;

  my $request = Foswiki::Func::getRequestObject();

  _writeDebug("called restTriggerStates()");

  throw Error::Simple("not allowed") unless Foswiki::Func::getContext()->{isadmin};

  # enter cron context
  Foswiki::Func::getContext()->{cronjob} = 1;

  my $isDry = Foswiki::Func::isTrue($request->param("dry"), 0);

  my $includeWeb = $request->param("includeweb");
  my $excludeWeb = $request->param("excludeweb");
  my $keepReviews = Foswiki::Func::isTrue($request->param("keepreviews"), 0);

  my @webs = split(/\s*,\s*/, $request->param("web") // $request->param("webs") // '');
  _writeDebug("webs=@webs");

  my $includeTopic = $request->param("includetopic");
  my $excludeTopic = $request->param("excludetopic");
  $includeTopic =~ s/,/|/g if $includeTopic;
  $excludeTopic =~ s/,/|/g if $excludeTopic;

  my $includeWorkflow = $request->param("includeworkflow");
  my $excludeWorkflow = $request->param("excludeworkflow");
  $includeWorkflow =~ s/,/|/g if $includeWorkflow;
  $excludeWorkflow =~ s/,/|/g if $excludeWorkflow;

  my $matches = Foswiki::Plugins::QMPlugin::TopicIterator->new(
    webs => \@webs,
    includeWeb => $includeWeb,
    excludeWeb => $excludeWeb,

    # TODO: more filter parameters to Foswiki::Plugins::QMPlugin::TopicIterator
    # includeTopic => $includeTopic,
    # excludeTopic => $excludeTopic,
    # includeWorkflow => $includeWorkflow,
    # excludeWorkflow => $excludeWorkflow,
  );

  my $index = 0;
  while ($matches->hasNext) {
    my ($web, $topic) = $matches->next;

    next if $includeTopic && $topic !~ /$includeTopic/;
    next if $excludeTopic && $topic =~ /$excludeTopic/;

    if (Foswiki::Func::topicExists($web, $topic.'Copy')) {
      _writeDebug("... found copy in ".$web.'.'.$topic."Copy ... skipping");
      next;
    }

    my $state = $this->getState($web, $topic);
    next unless $state;

    my $workflow = $state->prop("workflow");
    next unless defined $workflow && $workflow ne "";

    next if $includeWorkflow && $workflow !~ /$includeWorkflow/;
    next if $excludeWorkflow && $workflow =~ /$excludeWorkflow/;

    $index++;
    _writeDebug("processing topic=$web.$topic");
    _writeDebug("... workflow=$workflow");

    my $node = $state->getCurrentNode();
    unless (defined $node) {
      print STDERR "WARNING: $web.$topic - state undefined even though workflow '$workflow' is assigned\n";
      next;
    }
    _writeDebug("... current state=".$node->prop("id"));

    # loop until no more edges could be traversed
    my %seen = ();
    while (my @edges = $state->getTriggerableEdges()) {
      my $id = $state->prop("id");

      # prevent infinite recursion
      last if $seen{$id};
      $seen{$id} = 1;

      _writeDebug("... found qmstate in $web.$topic, id=$id");
      _writeDebug("... ".scalar(@edges)." edge(s) that can be triggered");

      my $edge = shift @edges;
      _writeDebug("... triggering edge ".$edge->stringify);

      my $error;
      my $hasChanged = 0;
      try {
        $hasChanged = $state->change($edge->prop("action"), $edge->prop("to"), undef, undef, $keepReviews);
      } catch Error::Simple with {
        $error = shift->stringify;
        print STDERR "ERROR: $error\n";

        $error =~ s/ at .*$//s;
      };

      throw Foswiki::Contrib::JsonRpcContrib::Error(1006, $error)
        if defined $error;

      if (!$isDry && $hasChanged) {
        try {
          $state->save(
            ignorepermissions => 1,
            forcenewrevision => 1,
            minor => 1
          );
        } catch Error with {
          $error = shift;
          print STDERR "ERROR: $error\n";
          throw Error::Simple("Sorry, there was an error when triggering the state.");
        };
      }
    }
  }
  _writeDebug("... tested $index topics"); 
  
  return '';
}

=begin TML

---++ ObjectMethod QMHISTORY($session, $params, $topic, $web)

macro implementation for =%QMHISTORY=

=cut

sub QMHISTORY {
  my ($this, $session, $params, $topic, $web) = @_;

  _writeDebug("called QMHISTORY()");

  $topic = $params->{_DEFAULT} if defined $params->{_DEFAULT};
  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $ignoreError = _ignoreError($params);
  return $ignoreError ? "" : _inlineError("topic not found") unless Foswiki::Func::topicExists($web, $topic);

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev");
  my $header = $params->{header};
  my $format = $params->{format};
  my $separator = $params->{separator};
  my $footer = $params->{footer};
  my $title = $params->{title} // Foswiki::Func::expandTemplate("qm::history::header::title");

  $title = "" if $title =~ /^(off|no|0|false)$/;
  $title = Foswiki::Func::expandTemplate("qm::history::header::title") if $title =~ /^(on|yes|1|true)$/;

  unless (defined $header || defined $format || defined $separator || defined $footer) {
    $header = Foswiki::Func::expandTemplate("qm::history::header");
    $format = Foswiki::Func::expandTemplate("qm::history::format");
    $footer = Foswiki::Func::expandTemplate("qm::history::footer");
    $separator = '';
  }

  $header //= '';
  $footer //= '';
  $format //= '';
  $separator //= '';

  my @states = $this->getStates($web, $topic, $rev, $params);
  _writeDebug(scalar(@states) . " state(s) found at $web.$topic");
  my $isReverse = Foswiki::Func::isTrue($params->{reverse}, 0);
  @states = reverse @states if $isReverse;

  my $sort = $params->{sort} || $params->{order} || "date";
  $sort = "id" if $sort eq "state";
  @states = _sortRecords(\@states, $sort) if defined $sort && $sort ne "date";

  my @result = ();

  my $index = 0;
  my $prevState;
  foreach my $state (@states) {
    $index++;
    $prevState = $states[$index] if $isReverse;

    my $line = $format;
    $line =~ s/\$duration\b/$prevState ? $state->prop("date") - $prevState->prop("date") : 0/ge;
    $line = $state->render($line, $params);
    $line =~ s/\$index\b/$index/g;
    $line =~ s/\$prevRev\b/$prevState?$prevState->getRevision():''/ge;
    push @result, $line if $line ne "";

    $prevState = $state unless $isReverse;
  }
  return "" unless @result;

  Foswiki::Plugins::JQueryPlugin::createPlugin('QMPlugin');
  my $result = $header . join($separator, @result) . $footer;
  my $count = scalar(@states);
  $result =~ s/\$count\b/$count/g;
  $result =~ s/\$title\b/$title/g;

  return Foswiki::Func::decodeFormatTokens($result);
}

=begin TML

---++ ObjectMethod QMNET($session, $params, $topic, $web)

macro implementation for =%QMNET=

=cut

sub QMNET {
  my ($this, $session, $params, $topic, $web) = @_;

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev") || "";
  my $ignoreError = _ignoreError($params);

  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  #_writeDebug("called QMNET: $web.$topic, rev=$rev");

  my $workflow = $params->{_DEFAULT} // $params->{workflow};
  my $net;
  my $state;

  if ($workflow) {
    my ($netWeb, $netTopic) = Foswiki::Func::normalizeWebTopicName($web, $workflow);
    return $ignoreError ? "" : _inlineError("workflow not found") unless Foswiki::Func::topicExists($netWeb, $netTopic);

    $net = $this->getNet($netWeb, $netTopic);
  } else {
    $state = $this->getState($web, $topic, $rev);
    if ($state) {
      $state->setWorkflow($workflow) if $workflow;
      $net = $state->getNet();
    }
  }

  return $ignoreError ? "" : _inlineError("no workflow not found") unless defined $net;
  $workflow //= $net->getDefinition();

  my $type = $params->{type} // 'nodes';
  my $format = $params->{format} // '$id';
  my $header = $params->{header} // '';
  my $footer = $params->{footer} // '';
  my $separator = $params->{separator} // '';
  my $icon = $params->{icon} // 'fa-circle';
  my $sort = $params->{sort} // 'off';


  my $include = $params->{include};
  my $exclude = $params->{exclude};
  my $skip = $params->{skip} // 0;
  my $limit = $params->{limit} // 0;
  my $from = $params->{from};
  my $to = $params->{to};
  my $action = $params->{action};

  if ((defined $from && $from eq 'current') || 
      (defined $to && $to eq 'current') || 
      (defined $include && $include eq 'current') ||
      (defined $exclude && $exclude eq 'current')) {

    unless ($state) {
      $state = $this->getState($web, $topic, $rev);
      $state->setWorkflow($workflow) if $state;
    }

    if ($state) {
      my $current = '^'.$state->getCurrentNode->prop("id").'$';
      $from = $current if defined $from && $from eq 'current';
      $to = $current if defined $to && $to eq 'current';
      $include = $current if defined $include && $include eq 'current';
      $exclude = $current if defined $include && $exclude eq 'current';
    }
  }

  my @filteredItems = ();
  foreach my $item ($net->getSortedItems($type, $sort)) {
    my $id = $item->prop("id");

    next if defined $include && $id !~ /$include/;
    next if defined $exclude && $id =~ /$exclude/;

    if ($type eq 'edges') {
      next if defined $from && $item->prop("from") ne $from;
      next if defined $to && $item->prop("to") ne $to;
      next if defined $action && $item->prop("action") ne $action;
    }

    push @filteredItems, $item;
  }

  my @results = ();
  my $index = 0;
  foreach my $item (@filteredItems) {
    my $id = $item->prop("id");

    next if defined $include && $id !~ /$include/;
    next if defined $exclude && $id =~ /$exclude/;

    if ($type eq 'edges') {
      next if defined $from && $item->prop("from") ne $from;
      next if defined $to && $item->prop("to") ne $to;
      next if defined $action && $item->prop("action") ne $action;
    }

    $index++;
    next if $skip && $index <= $skip;

    my $line = $format;
    $line = $item->render($line, {icon => $icon});

    push @results, $line if $line ne '';
    last if $limit && $index >= $limit;
  }

  return "" unless @results;

  my $result = $header.join($separator, @results).$footer;
  my $count = scalar(@results);
  my $defaultNode = $net->getDefaultNode;
  my $defaultID = $defaultNode->prop("id");

  $result =~ s/\$web\b/$web/g;
  $result =~ s/\$topic\b/$topic/g;
  $result =~ s/\$workflow\b/$workflow/g;
  $result =~ s/\$count\b/$count/g;
  $result =~ s/\$defaultNode\b/$defaultID/g;

  return Foswiki::Func::decodeFormatTokens($result);
}

=begin TML

---++ ObjectMethod QMSTATE($session, $params, $topic, $web)

macro implementation for =%QMSTATE=

=cut

sub QMSTATE {
  my ($this, $session, $params, $topic, $web) = @_;

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev");
  my $ignoreError = _ignoreError($params);
  my $template = $params->{template} || 'qm::state';
  my $format = $params->{format} // Foswiki::Func::expandTemplate($template);

  $topic = $params->{_DEFAULT} if defined $params->{_DEFAULT};
  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  #_writeDebug("called QMSTATE: $web.$topic, rev=$rev");

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $workflow = $params->{workflow};
  $state->setWorkflow($workflow) if $workflow;

  #_writeDebug("state=".$state->stringify());

  return $ignoreError ? "" : _inlineError("qmstate workflow not found") unless defined $state->getNet();

  Foswiki::Plugins::JQueryPlugin::createPlugin('QMPlugin');
  return Foswiki::Func::decodeFormatTokens($state->render($format, $params));
}


=begin TML

---++ ObjectMethod QMNODE($session, $params, $topic, $web)

macro implementation for =%QMNODE=

=cut

sub QMNODE {
  my ($this, $session, $params, $topic, $web) = @_;

  #_writeDebug("called QMNODE()");

  my $request = Foswiki::Func::getRequestObject();
  my $format = $params->{format} // '$id, $title, $message';
  my $rev = $params->{rev} || $request->param("rev");
  my $id = $params->{_DEFAULT} || $params->{id};
  my $ignoreError = _ignoreError($params);

  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $net;

  if (defined $params->{workflow}) {
    my $workflow = $params->{workflow} || $state->prop("workflow") || "$web.$topic";
    $state->setWorkflow($workflow) if $workflow;

    my ($netWeb, $netTopic) = Foswiki::Func::normalizeWebTopicName($web, $workflow);
    return $ignoreError ? "" : _inlineError("workflow not found") unless Foswiki::Func::topicExists($netWeb, $netTopic);

    $net = $this->getNet($netWeb, $netTopic, $state);
  } else {
    $net = $state->getNet();
  }

  return $ignoreError ? "" : _inlineError("unknow workflow") unless defined $net;

  my $node;

  if (defined $id) {
    $node = $net->getNode($id);
  } else {
    $node = $state->getCurrentNode() if defined $state;
    $node = $net->getDefaultNode();
  }

  return $ignoreError ? "" : _inlineError("unknown node") unless defined $node;

  return Foswiki::Func::decodeFormatTokens($node->render($format));
}

=begin TML

---++ ObjectMethod QMROLE($session, $params, $topic, $web)

macro implementation for =%QMROLE=

=cut

sub QMROLE {
  my ($this, $session, $params, $topic, $web) = @_;

  #_writeDebug("called QMROLE()");

  my $request = Foswiki::Func::getRequestObject();
  my $format = $params->{format} // '$members';
  my $rev = $params->{rev} || $request->param("rev");
  my $id = $params->{_DEFAULT} || $params->{id};
  my $ignoreError = _ignoreError($params);

  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $net;

  if (defined $params->{workflow}) {
    my $workflow = $params->{workflow} || $state->prop("workflow") || "$web.$topic";
    $state->setWorkflow($workflow) if $workflow;

    my ($netWeb, $netTopic) = Foswiki::Func::normalizeWebTopicName($web, $workflow);
    return $ignoreError ? "" : _inlineError("workflow not found") unless Foswiki::Func::topicExists($netWeb, $netTopic);

    $net = $this->getNet($netWeb, $netTopic, $state);
  } else {
    $net = $state->getNet();
  }

  return $ignoreError ? "" : _inlineError("unknow workflow") unless defined $net;

  my $role;
  if (defined $id) {
    $role = ($id =~ /^admin/i) ? $net->getAdminRole : $net->getRole($id);
  }

  return $ignoreError ? "" : _inlineError("unknown role") unless defined $role;

  return Foswiki::Func::decodeFormatTokens($role->render($format));
}

=begin TML

---++ ObjectMethod QMEDGE($session, $params, $topic, $web)

macro implementation for =%QMEDGE=

=cut

sub QMEDGE {
  my ($this, $session, $params, $topic, $web) = @_;

  #_writeDebug("called QMEDGE()");

  my $format = $params->{format} // '$from, $action, $to';
  my $ignoreError = _ignoreError($params);

  my $from = $params->{from};
  my $action = $params->{action};
  my $to = $params->{to};
  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev");

  $topic = $params->{_DEFAULT} if defined $params->{_DEFAULT};
  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $net;

  if (defined $params->{workflow}) {
    my $workflow = $params->{workflow} || $state->prop("workflow") || "$web.$topic";
    $state->setWorkflow($workflow) if $workflow;

    my ($netWeb, $netTopic) = Foswiki::Func::normalizeWebTopicName($web, $workflow);
    return $ignoreError ? "" : _inlineError("workflow not found") unless Foswiki::Func::topicExists($netWeb, $netTopic);

    $net = $this->getNet($netWeb, $netTopic, $state);
  } else {
    $net = $state->getNet();
  }

  return $ignoreError ? "" : _inlineError("unknown workflow") unless defined $net;

  my $edge;

  if (defined $from || defined $to || defined $action) {
    $edge = $net->getEdge($from, $action, $to);
  } else {
    $edge = $state->getCurrentEdge() if defined $state;
  }

  return $ignoreError ? "" : _inlineError("unknown edge") unless defined $edge;

  my $icon = $params->{icon} // 'fa-circle';
  return Foswiki::Func::decodeFormatTokens($edge->render($format, {icon => $icon}));
}

=begin TML

---++ ObjectMethod QMGRAPH($session, $params, $topic, $web)

macro implementation for =%QMGRAPH=

=cut

sub QMGRAPH {
  my ($this, $session, $params, $topic, $web) = @_;

  #_writeDebug("called QMGRAPH()");

  my $ignoreError = _ignoreError($params);

  unless (Foswiki::Func::getContext()->{GraphvizPluginEnabled}) {
    return $ignoreError ? "" : _inlineError("<nop>GraphvizPlugin not installed");
  }

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev");

  $topic = $params->{_DEFAULT} if defined $params->{_DEFAULT};
  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $net;

  if (defined $params->{workflow}) {
    my $workflow = $params->{workflow} || $state->prop("workflow") || "$web.$topic";
    $state->setWorkflow($workflow) if $workflow;

    my ($netWeb, $netTopic) = Foswiki::Func::normalizeWebTopicName($web, $workflow);
    return $ignoreError ? "" : _inlineError("workflow not found") unless Foswiki::Func::topicExists($netWeb, $netTopic);

    $net = $this->getNet($netWeb, $netTopic, $state);
  } else {
    $net = $state->getNet();
  }

  return $ignoreError ? "" : _inlineError("unknow workflow") unless defined $net;

  return $net->getDot($params);
  #return $net->getVis($params);
}

=begin TML

---++ ObjectMethod QMBUTTON($session, $params, $topic, $web)

macro implementation for =%QMBUTTON=

=cut

sub QMBUTTON {
  my ($this, $session, $params, $topic, $web) = @_;

  #_writeDebug("called QMBUTTON()");

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $params->{rev} || $request->param("rev");

  $topic = $params->{topic} if defined $params->{topic};
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  my $ignoreError = _ignoreError($params);

  my $state = $this->getState($web, $topic, $rev);
  return $ignoreError ? "" : _inlineError("no qmstate found") unless $state;

  my $workflow = $params->{workflow} || $state->prop("workflow");
  $state->setWorkflow($workflow) if $workflow;

  return "" unless $workflow;

  my $action = $params->{action} // '';;
  my @edges = grep {$_->prop("action") ne "_hidden_"} $state->getPossibleEdges();
  @edges = grep { $_->prop("action") =~ /^\Q$action\E$/i} @edges if $action;

  my $showComment = Foswiki::Func::isTrue($params->{showcomment}, 1);
  my $isEnabled = scalar(@edges) ? 1 : 0;
  my $isSingleAction = scalar(@edges) == 1 ? 1 : 0;
  $isEnabled = 0 if defined $rev;

  $rev //= '';

  my $title = $isSingleAction ? $edges[0]->prop("title") : "Change State";
  my $text = $params->{_DEFAULT} || $params->{text} || $title;
  my $icon = $params->{icon} || ($isSingleAction ? $edges[0]->prop("icon") || 'fa-certificate' : 'fa-certificate');
  my $class = $params->{class};
  my $template = $params->{template} || ($isSingleAction && !$showComment ? 'qm::button::action' : 'qm::button');

  my @class = ();
  push @class, "foswikiDialogLink" unless $isSingleAction && !$showComment;
  push @class, "qmChangeStateButton";
  push @class, "jqButtonDisabled" unless $isEnabled;
  push @class, $class if $class;
  $class = join(" ", @class);


  my $result = $params->{format} // Foswiki::Func::expandTemplate($template) // '';

  $result =~ s/\$text\b/$text/g;
  $result =~ s/\$icon\b/$icon/g;
  $result =~ s/\$class\b/$class/g;
  $result =~ s/\$workflow\b/$workflow/g;
  $result =~ s/\$web\b/$web/g;
  $result =~ s/\$topic\b/$topic/g;
  $result =~ s/\$rev\b/$rev/g;
  $result =~ s/\$action\b/$action/g;
  $result =~ s/\$showcomment\b/$showComment?'on':'off'/ge;

  return Foswiki::Func::decodeFormatTokens($result);
}

=begin TML

---++ ObjectMethod getState($web, $topic, $rev, $meta, $force) -> $state

get the workflow state of the given topic

=cut

sub getState {
  my ($this, $web, $topic, $rev, $meta, $force) = @_;

  $rev = $meta->getLoadedRev() if defined $meta;

  # get cached state
  my $key = _getWebTopicKey($web, $topic, $rev);
  my $state;
  $state = $this->{_states}{$key} unless $force;

  unless (defined $state) {
    _writeDebug("getState($web, $topic, ".($rev//'undef').")");
    $this->{_states}{$key} = '_undef_'; # prevent deep recursion

    $state = Foswiki::Plugins::QMPlugin::State->new($web, $topic, $rev, $meta);

    # cache state
    if ($state) {
      $key = _getWebTopicKey($web, $topic, $state->getRevision());
      $this->{_states}{$key} = $state;

      if ($state->getMeta->latestIsLoaded()) {
        $key = _getWebTopicKey($web, $topic, 0);
        $this->{_states}{$key} = $state;
      }
    }
  }

  return ref($state) ? $state : undef;
}

=begin TML

---++ ObjectMethod getNet($web, $topic, $state) -> $net

returns a Foswiki::Plugins::QMPlugin::Net object and assignes the given state.

=cut

sub getNet {
  my $this = shift;
  my $web = shift;
  my $topic = shift;
  my $state = shift;

  my $key = $web."::".$topic;
  $key =~ s/\//./g;

  my $net = $this->{_nets}{$key};
  if ($net) {
    $net->setState($state);
  } else {
    $this->{_nets}{$key} = $net = Foswiki::Plugins::QMPlugin::Net->new($web, $topic, $state, @_);
  }

  return $net;
}

=begin TML

---++ ObjectMethod getStates($web, $topic, $rev, $params) -> @states

get all workflow states of the given topic up to revision =$rev=

=cut

sub getStates {
  my ($this, $web, $topic, $rev, $params) = @_;

  $rev ||= 0;
  _writeDebug("called getStates($web, $topic, $rev)");

  my @states = ();
  my $maxRev = $rev;
  (undef, undef, $maxRev) = Foswiki::Func::getRevisionInfo($web, $topic) unless $maxRev;
  $maxRev ||= 1;

  my $untilState = $params->{until_state};
  my $prevKey;

  my $skip = $params->{skip} || 0;
  my $limit = ($params->{limit} || 0) + $skip;
  my $index = 0;
  
  for (my $i = $maxRev ; $i > 0 ; $i--) {
    my $state = $this->getState($web, $topic, $i);
    next unless $state;
    
    # SMELL: too unreliable as by now
    #next unless $state->prop("changed") || $i == 1;

    my $date = $state->prop("date");
    my $edge = $state->getCurrentEdge();
    my $key = ($edge ? $edge->stringify() : "").", $date";
    next if $prevKey && $key eq $prevKey;
    $prevKey = $key;

    my $workflow = $params->{workflow} || $state->prop("workflow");
    $state->setWorkflow($workflow) if $workflow;
    next unless defined $state->prop("id");

    my @comments = map {$_->{text}} $state->getComments();
    my $comment = $comments[-1] // '';

    # filter
    next if defined $params->{filter_action} && ($state->prop("reviewAction") || $state->prop("previousAction")) !~ /$params->{filter_action}/;
    next if defined $params->{filter_author} && $state->prop("author") !~ /$params->{filter_author}/;
    next if defined $params->{filter_comment} && $comment !~ /$params->{filter_comment}/;
    next if defined $params->{from_date} && $date < $params->{from_date};
    last if defined $params->{to_date} && $date > $params->{to_date};
    next if defined $params->{filter_message} && $state->prop("message") !~ /$params->{filter_message}/;
    next if defined $params->{filter_reviewer} && join(", ", $state->getReviewedBy()) !~ /$params->{filter_reviewer}/;
    next if defined $params->{filter_state} && $state->prop("id") !~ /$params->{filter_state}/;

    $index++;
    next if $index <= $skip;
    push @states, $state;

    # limit
    last if defined $params->{until_action} && ($state->prop("reviewAction") || $state->prop("previousAction")) =~ /$params->{until_action}/;
    last if defined $params->{until_author} && $state->prop("author") =~ /$params->{until_author}/;
    last if defined $params->{until_comment} && $comment =~ /$params->{until_comment}/;
    last if defined $params->{until_message} && $state->prop("message") =~ /$params->{until_message}/;
    last if defined $params->{until_reviewer} && join(", ", $state->getReviewedBy()) =~ /$params->{until_reviewer}/;

    if (defined $untilState && $untilState =~ /\$approval(ID)?\b/) {
      my $net = $state->getNet();
      next unless $net;

      my $approvalRegex = '\b('. join("|", map {$_->prop("id")} $net->getApprovalNodes). ')\b';
      $untilState =~ s/\$approval(ID)?\b/$approvalRegex/g;
    }

    last if defined $untilState && $state->prop("id") =~ /$untilState/;
    last if $limit && $index >= $limit;
  }

  return reverse @states;
}

=begin TML

---++ ObjectMethod registerCommandHandler($handler) 

register a command handler. commands are executed when an edge is traversed.

The handler is a hash reference with the following properties:

   * id: name of the command that may is executed, e.g. "fork", "merge" or "trash"
   * type: type of the command: "beforeSave", "afterSave"
   * package: perl package
   * function: function within the package to be called 
   * callback: callback function

Note that either "package" and "function" are specified, or a "callback" is given right away.

=cut

sub registerCommandHandler {
  my ($this, $handler) = @_;

  return unless defined $handler;

  #_writeDebug("registerCommandHandler for $handler->{id} in $handler->{package}");

  $this->{_commandHandler}{lc($handler->{id})} ||= ();
  push @{$this->{_commandHandler}{lc($handler->{id})}}, $handler;
}

=begin TML 

---++ ObjectMethod getCommandHandlers($id) -> @callbacks

get the list of registered handlers for a specified action id

=cut

sub getCommandHandlers {
  my ($this, $id) = @_;

  $id = lc($id);
  my $handlers = $this->{_commandHandler}{$id};

  unless (defined $handlers) {
    print STDERR "ERROR: unknown command '$id'\n";
    return;
  }

  foreach my $handler (@$handlers) {
    if (defined($handler->{package}) && defined($handler->{function}) && !defined($handler->{callback})) {

      my $pkg = $handler->{package};

      my $pm = "$pkg.pm";
      $pm =~ s/::/\//g;
      
      eval { require $pm };
      if ($@) {
        print STDERR "ERROR: $@\n";
        return;
      };

      $handler->{callback} = \&{$handler->{package} . "::" . $handler->{function}};
    }
  }

  return @$handlers;
}

=begin TML

---++ ObjectMethod redirectUrl(url)

the redirect property records the need of the system to initiate a redirect
at the end of the processing queue

=cut

sub redirectUrl {
  my ($this, $url) = @_;

  $this->{_redirectUrl} = $url if defined $url;
  return $this->{_redirectUrl};
}

=begin TML

---++ ObjectMethod solrIndexTopicHandler($indexer, $doc, $web, $topic, $meta, $text) 

hooks into the solr indexer and add workflow fields

=cut

sub solrIndexTopicHandler {
  my ($this, $indexer, $doc, $web, $topic, $meta, $text) = @_;

  _writeDebug("called solrIndexTopicHandler($web, $topic)");
  my $state = $this->getState($web, $topic);
  return unless $state;

  my $workflow = $state->prop("workflow");
  return unless $state;

  my $node = $state->getCurrentNode();
  return unless $node;

  my $nodeId = $state->prop("id");
  return unless defined $nodeId;

  my $nodeTitle = $state->expandValue($node->prop("title"));
  my @reviewers = sort $state->getReviewers();
  my @pendingApprovers = sort map{$_->prop("wikiName") || $_->prop("id")} $state->getPendingApprovers();
  my @pendingReviewers = sort map{$_->prop("wikiName") || $_->prop("id")} $state->getPendingReviewers();
  my @possibleReviewers = sort map{$_->prop("wikiName") || $_->prop("id")} $state->getPossibleReviewers();

  my $stateField = $indexer->getField($doc, "state");
  if ($stateField) {
    $stateField->value($nodeId);
  } else {
    $doc->add_fields(
      state => $nodeId
    );
  }

  $doc->add_fields(
    field_QMWorkflow_s => $workflow,
    field_QMStateID_s => $nodeId,
    field_QMStateTitle_s => $nodeTitle,

    field_QMStateReviewers_lst => \@reviewers,
    field_QMStateReviewers_s => join(", ", @reviewers),

    field_QMStatePendingApprovers_lst => \@pendingApprovers,
    field_QMStatePendingApprovers_s => join(", ", @pendingApprovers),

    field_QMStatePendingReviewers_lst => \@pendingReviewers,
    field_QMStatePossibleReviewers_s => join(", ", @possibleReviewers),
  );
}

=begin TML


---++ ObjectMethod solrIndexAttachmentHandler($indexer, $doc, $web, $topic, $attachment) 

hooks into the solr indexer and add workflow fields

=cut

sub solrIndexAttachmentHandler {
  my ($this, $indexer, $doc, $web, $topic, $attachment) = @_;

  _writeDebug("called solrIndexAttachmentHandler($web, $topic)");

  my $state = $this->getState($web, $topic);
  return unless $state && $state->prop("workflow");

  my $node = $state->getCurrentNode();
  return unless $node;

  my $nodeId = $state->prop("id");
  return unless defined $nodeId;

  my $nodeTitle = $state->expandValue($node->prop("title"));

  $doc->add_fields(
    state => $nodeId,

    field_QMStateID_s => $nodeId,
    field_QMStateTitle_s => $nodeTitle,
  );
}

=begin TML

---++ ObjectMethod dbCacheIndexTopicHandler($db, $obj, $web, $topic, $meta, $text)

hooks into the dbcache indexer and add workflow fields

=cut

sub dbCacheIndexTopicHandler {
  my ($this, $db, $obj, $web, $topic, $meta, $text) = @_;

  my $state = $this->getState($web, $topic, undef, $meta);
  return unless $state && $state->prop("workflow");

  _writeDebug("called dbCacheIndexTopicHandler($web, $topic)");
  _writeDebug("workflow=".$state->prop("workflow"));

  my $qmo = $obj->fastget("qmstate");

  my $node = $state->getCurrentNode();
  return unless $node;

  my $title = $state->expandValue($node->prop("title"));
  my $reviewers = join(", ", sort map {$_->prop("wikiName")} $state->getReviewers());
  my $pendingApprovers= join(", ", sort map{$_->prop("wikiName") || $_->prop("id")} $state->getPendingApprovers());
  my $pendingReviewers = join(", ", sort map{$_->prop("wikiName") || $_->prop("id")} $state->getPendingReviewers());
  my $possibleReviewers = join(", ", map{$_->prop("wikiName") || $_->prop("id")} sort $state->getPossibleReviewers());
  my $progress = ($state->getCurrentSignOff() // 0) * 100;
  my $index = $node->index;

  unless ($qmo) {
    $qmo = $db->{archivist}->newMap();
    $qmo->set('id', $node->prop("id"));
    $obj->set("qmstate", $qmo);
  }

  $qmo->set('title', $title);
  $qmo->set('index', $index);
  $qmo->set('pendingApprovers', $pendingApprovers) if $pendingApprovers;
  $qmo->set('pendingReviewers', $pendingReviewers) if $pendingReviewers;
  $qmo->set('possibleReviewers', $possibleReviewers) if $possibleReviewers;
  $qmo->set('reviewers', $reviewers) if $reviewers;
  $qmo->set('progress', $progress);
}

sub setTemplateName {
  my ($this, $web, $topic) = @_;

  my $request = Foswiki::Func::getRequestObject();
  my $rev = $request->param("rev");
  my $template = $request->param("template");
  return if $template;
  
  return unless Foswiki::Func::topicExists($web, $topic);
  my ($meta) = Foswiki::Func::readTopic($web, $topic, $rev);
  my $qmData = $meta->get("QMSTATE");
  return unless $qmData;

  _setPreferenceName('VIEW_TEMPLATE', $qmData->{viewTemplate});
  _setPreferenceName('EDIT_TEMPLATE', $qmData->{editTemplate});
  _setPreferenceName('PRINT_TEMPLATE', $qmData->{printTemplate});
}

###
### private static functions
###

sub _setPreferenceName {
  my ($var, $val) = @_;

  return unless $val;

  $var =~ s/^PRINT_/VIEW_/g;    #sneak in VIEW again

  if ($Foswiki::Plugins::VERSION >= 2.1) {
    Foswiki::Func::setPreferencesValue($var, $val);
  } else {
    $Foswiki::Plugins::SESSION->{prefs}->pushPreferenceValues('SESSION', {$var => $val});
  }
}

sub _inlineError {
  my $msg = shift;

  $msg =~ s/ at \/.*$//;
  return "<span class='foswikiAlert'>ERROR: " . $msg . "</span>";
}

sub _getWebTopicKey {
  my ($web, $topic, $rev) = @_;

  $rev ||= 0;
  $web =~ s/\//./g;    # normalize web name

  my $key = $web . "::" . $topic . "::" . $rev;

  #_writeDebug("key=$key");

  return $key;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Core - $_[0]\n";
}

sub _sortRecords {
  my ($records, $crit) = @_;

  my $isNumeric = 1;
  my $isDate = 1;
  my %sortCrits = ();
  foreach my $rec (@$records) {
    my $val;
    if ($crit eq 'random') {
      $val = rand();
    } else {
      $val = '';
      foreach my $key (split(/\s*,\s*/, $crit)) {
        my $v = $rec->prop($key);
        next unless defined $v;
        $v =~ s/^\s*|\s*$//g;
        $val .= $v;
      }
    }
    next unless defined $val;

    if ($isNumeric && $val !~ /^(\s*[+-]?\d+(\.?\d+)?\s*)$/) {
      $isNumeric = 0;
    }

    if (!$isNumeric && $isDate) {
      my $epoch = Foswiki::Time::parseTime($val);
      if (defined $epoch) {
        $val = $epoch;
      } else {
        $isDate = 0;
      }
    }

    $sortCrits{$rec->{date}} = $val;
  }

  $isNumeric = 1 if $isDate;

  my @result;

  if ($isNumeric) {
    @result = sort { ($sortCrits{$a->{date}} || 0) <=> ($sortCrits{$b->{date}} || 0) } @$records;
  } else {
    @result = sort { lc($sortCrits{$a->{date}} || '') cmp lc($sortCrits{$b->{date}} || '') } @$records;
  }

  return @result;
}

sub _ignoreError {
  my $params = shift;

  return Foswiki::Func::isTrue($params->{ignoreerror}, 0) 
    if defined $params->{ignoreerror};

  return (Foswiki::Func::isTrue($params->{warn}, 1) ? 0 : 1)
    if defined $params->{warn};

  return 0;
}

1;
