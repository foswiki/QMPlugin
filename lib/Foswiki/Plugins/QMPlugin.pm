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

package Foswiki::Plugins::QMPlugin;

=begin TML

---+ package Foswiki::Plugins::QMPlugin

base class to hook into the foswiki core

=cut

use strict;
use warnings;

use Foswiki::Func ();
use Foswiki::Plugins::JQueryPlugin ();
use Foswiki::Contrib::JsonRpcContrib ();

our $VERSION = '0.9993';
our $RELEASE = '28 Jan 2021';
our $SHORTDESCRIPTION = 'Workflow Engine for Quality Management';
our $NO_PREFS_IN_TOPIC = 1;
our $core;

=begin TML

---++ initPlugin($topic, $web, $user) -> $boolean

initialize the plugin, automatically called during the core initialization process

=cut

sub initPlugin {

  Foswiki::Plugins::JQueryPlugin::registerPlugin('QMPlugin', 'Foswiki::Plugins::QMPlugin::JQuery');
  Foswiki::Func::registerTagHandler('QMBUTTON', sub { return getCore()->QMBUTTON(@_); });
  Foswiki::Func::registerTagHandler('QMEDGE', sub { return getCore()->QMEDGE(@_); });
  Foswiki::Func::registerTagHandler('QMGRAPH', sub { return getCore()->QMGRAPH(@_); });
  Foswiki::Func::registerTagHandler('QMHISTORY', sub { return getCore()->QMHISTORY(@_); });
  Foswiki::Func::registerTagHandler('QMNODE', sub { return getCore()->QMNODE(@_); });
  Foswiki::Func::registerTagHandler('QMROLE', sub { return getCore()->QMROLE(@_); });
  Foswiki::Func::registerTagHandler('QMSTATE', sub { return getCore()->QMSTATE(@_); });
  Foswiki::Func::registerTagHandler('QMNET', sub { return getCore()->QMNET(@_); });

  Foswiki::Func::registerRESTHandler('triggerStates', sub { return getCore()->restTriggerStates(@_); },
    validate => 1,
    authenticate => 1,
    http_allow => 'GET,POST',
  );

  Foswiki::Contrib::JsonRpcContrib::registerMethod("QMPlugin", "changeState", sub {
    return getCore()->jsonRpcChangeState(@_);
  });

  Foswiki::Contrib::JsonRpcContrib::registerMethod("QMPlugin", "sendNotification", sub {
    return getCore()->jsonRpcSendNotification(@_);
  });

  Foswiki::Contrib::JsonRpcContrib::registerMethod("QMPlugin", "cancelTransition", sub {
    return getCore()->jsonRpcCancelTransition(@_);
  });

  if ($Foswiki::Plugins::VERSION > 2.0) {
    Foswiki::Func::registerMETA('QMSTATE', alias => 'qmstate');
    Foswiki::Func::registerMETA('QMREVIEW', alias => 'qmreview', many => 1);
    
    # backwards compatibility
    unless ($Foswiki::cfg{Plugins}{WorkflowPlugin} && $Foswiki::cfg{Plugins}{WorkflowPlugin}{Enabled}) {
      Foswiki::Meta::registerMETA('WORKFLOW');
      Foswiki::Meta::registerMETA( 'WORKFLOWHISTORY', many => 1 );
    }
  }

  if ($Foswiki::cfg{Plugins}{SolrPlugin} && $Foswiki::cfg{Plugins}{SolrPlugin}{Enabled}) {
    require Foswiki::Plugins::SolrPlugin;
    Foswiki::Plugins::SolrPlugin::registerIndexTopicHandler(sub {
      return getCore()->solrIndexTopicHandler(@_);
    });
  }

  if ($Foswiki::cfg{Plugins}{DBCachePlugin} && $Foswiki::cfg{Plugins}{DBCachePlugin}{Enabled}) {
    require Foswiki::Plugins::DBCachePlugin;
    Foswiki::Plugins::DBCachePlugin::registerIndexTopicHandler(sub {
      return getCore()->dbCacheIndexTopicHandler(@_);
    });
  }

  return 1;
}

=begin TML

---++ finishPlugin

finish the plugin and the core if it has been used,
automatically called during the core initialization process

=cut

sub finishPlugin {
  $core->finish () if defined $core;
  undef $core;
}

=begin TML

---++ getCore() -> $core

returns a singleton Foswiki::Plugins::QMPlugin::Core object for this plugin; a new core is allocated 
during each session request; once a core has been created it is destroyed during =finishPlugin()=

=cut

sub getCore {
  unless (defined $core) {
    require Foswiki::Plugins::QMPlugin::Core;
    $core = Foswiki::Plugins::QMPlugin::Core->new();
  }
  return $core;
}

=begin TML

---++ beforeSaveHandler($text, $topic, $web, $meta )

make sure the saved topic has got the right access control settings

=cut

sub beforeSaveHandler {
  my ($text, $topic, $web, $meta) = @_;

  getCore()->beforeSaveHandler($web, $topic, $meta);
}

=begin TML

---++ registerCommandHandler($id, $type, $handler)

register a function that can be refered to by the given id.
there are two types of handler:

   * beforeSave: function is called before a state is saved
   * afterSave: function is called after a state is saved

=cut

sub registerCommandHandler {
  getCore()->registerCommandHandler(@_);
}

1;
