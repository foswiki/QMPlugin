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

package Foswiki::Plugins::QMPlugin::Handler::CreateTopic;

use strict;
use warnings;

use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Meta ();
use Foswiki::Plugins ();
use Foswiki::Form ();
use Foswiki::Plugins::QMPlugin ();
use Foswiki::Plugins::QMPlugin::Utils qw(:all);
#use Data::Dump qw(dump);

use constant TRACE => 0; # toggle me

=begin TML

---++ ObjectMethod handle($command, $state) 

implements the =createTopic= workflow command

known parameters:

   * _DEFAULT or topic: topic name to be created, can be a full web.topic 
   * web: web to create the topic in, defaults to the current state's web
   * overwrite: boolean switch to overwrite any existing topic, defaults to off thus warning when the same topic is about to be created again
   * template: topic name of a template topic to be used
   * parent: parent topic 
   * text: new text
   * form: topic name of a form to be attached
   * redirectto: web.topic name to redirect to after the topic has been created, can be a full http url as well
   * redirect: boolean switch to redirect to the newly created topic
   * &lt;fieldName>: value for the given field

=cut

sub handle {
  my ($command, $state) = @_;

  _writeDebug("called handle()");

  my $params = $command->getParams();
  #_writeDebug("... params=".dump($params));

  # get web and topic
  my $web = $params->{web} || $state->getWeb();
  my $topic = $params->{_DEFAULT} || $params->{topic};

  throw Error::Simple("no topic parameter")
    unless $topic;
 
  ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);

  $topic = expandAUTOINC($web, $topic); 

  my $overwrite = Foswiki::Func::isTrue($params->{overwrite}, 0);
  _writeDebug("... overwrite=$overwrite");

  throw Error::Simple("topic already exists")
    if !$overwrite && Foswiki::Func::topicExists($web, $topic);

  # create topic
  my $session = $Foswiki::Plugins::SESSION;
  my $newMeta = Foswiki::Meta->new($session, $web, $topic);

  # init from template
  my $templateWeb = $web;
  my $templateTopic = $params->{template};
  my $templateMeta;
  if ($templateTopic) {
    ($templateWeb, $templateTopic) = Foswiki::Func::normalizeWebTopicName($templateWeb, $templateTopic);

    throw Error::Simple("template does not exist")
      unless Foswiki::Func::topicExists($templateWeb, $templateTopic);

    ($templateMeta) = Foswiki::Func::readTopic($templateWeb, $templateTopic);

    throw Error::Simple("access to template denied") 
      unless $templateMeta->haveAccess("VIEW");
  }

  if ($templateMeta) {
    $newMeta->text($templateMeta->text);

    foreach my $k (keys %$templateMeta) {
      next if $k =~ /^(_|TOPIC|FILEATTACHMENT)/;
      $newMeta->copyFrom($templateMeta, $k);
    }
  } 

  # set text
  my $text = $params->{text};
  $newMeta->text($text) if defined $text;

  $newMeta->expandNewTopic();

  # set topic parent
  my $parentTopic = $params->{parent};
  my $parentWeb = $web;

  if ($parentTopic) {
    if ($parentTopic eq 'none') {
      $newMeta->remove('TOPICPARENT');
    } else {
      ($parentWeb, $parentTopic) = Foswiki::Func::normalizeWebTopicName($parentWeb, $parentTopic);
      $newMeta->put('TOPICPARENT', {
        'name' => ($parentWeb eq $web) ? $parentTopic: "$parentWeb.$parentTopic",
      });
    }
  }

  # set form
  my $formWeb = $web;
  my $formTopic = $params->{form};
  my $formMeta;

  if ($formTopic) {
    ($formWeb, $formTopic) = Foswiki::Func::normalizeWebTopicName($formWeb, $formTopic);

    throw Error::Simple("form does not exist")
      unless Foswiki::Func::topicExists($formWeb, $formTopic);

    ($formMeta) = Foswiki::Func::readTopic($formWeb, $formTopic);

    throw Error::Simple("access to form denied") 
      unless $formMeta->haveAccess("VIEW");
  }

  if ($formMeta) {
    my $formDef = Foswiki::Form->new($session, $formWeb, $formTopic);

    $newMeta->put('FORM', {name => "$formWeb.$formTopic"});

    # Remove fields that don't exist on the new form def.
    my $filter = join(
      '|', map { $_->{name} }
        grep { $_->{name} } @{$formDef->getFields()}
    );
    foreach my $f ($newMeta->find('FIELD')) {
      if ($f->{name} !~ /^($filter)$/) {
        $newMeta->remove('FIELD', $f->{name});
      }
    }

    # override fields with values from the params
    foreach my $fieldDef (@{$formDef->getFields()}) {
      my $name = $fieldDef->{name};
      my $title = $fieldDef->{title};

      my $value = $params->{$name};
      next unless defined $value;

      _writeDebug("... setting $name=$value");

      $newMeta->putKeyed('FIELD', {
        name => $name,
        title => $title,
        value => $value,
      });
    }
  }
  
  _writeDebug("creating new topic ".$newMeta->getPath);

  throw Error::Simple("Access denied") unless $newMeta->haveAccess("CHANGE");
  $state->getCore->saveMeta($newMeta,
    ignorepermissions => 1,
    forcenewrevision => 1,
    @_
  );

  my $redirectUrl;
  my $redirectTo = $params->{redirectto};

  if ($redirectTo) {
    if ($redirectTo =~ /^https?:\/\// || $redirectTo =~ /^\//) {
      $redirectUrl = $redirectTo;
    } else {
      my ($redirectWeb, $redirectTopic) = Foswiki::Func::normalizeWebTopicName($web, $redirectTo);
      $redirectUrl = Foswiki::Func::getScriptUrlPath($redirectWeb, $redirectTopic, "view")
    }
  } else {
    my $doRedirect = Foswiki::Func::isTrue($params->{redirect}, 0);
    if ($doRedirect) {
      _writeDebug("redirecting to ".$newMeta->getPath());
      $redirectUrl = Foswiki::Func::getScriptUrlPath($newMeta->web, $newMeta->topic, "view");
    }
  }

  $state->getCore->redirectUrl($redirectUrl) if $redirectUrl;

  _writeDebug("done");
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::CreateTopic - $_[0]\n";
}

1;

