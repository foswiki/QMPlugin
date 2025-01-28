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

package Foswiki::Plugins::QMPlugin::Utils;

=begin TML

---+ package Foswiki::Plugins::QMPlugin::Utils

This package exports a few operations on topics and attachments
to ease copying, moving and trashing them with ease. All functions
operate on Foswiki::Meta objects.

=cut

use strict;
use warnings;

use Exporter;
our @ISA = ('Exporter');
our @EXPORT_OK = qw(
      trashTopic moveTopic copyTopic renameTopic expandAUTOINC
      trashAttachments trashAttachment copyAttachments copyAttachment
    );
our %EXPORT_TAGS = (
  all => [qw(
      trashTopic moveTopic copyTopic renameTopic expandAUTOINC
      trashAttachments trashAttachment copyAttachments copyAttachment
    )
  ]
);

use constant TRACE => 0; # toggle me

use Foswiki();
use Foswiki::Func ();
use Foswiki::Meta ();
use Foswiki::Plugins ();
use Foswiki::Plugins::QMPlugin ();

=begin TML

---++ StaticMethod trashTopic($meta)

moves a topic object to the trash web. see also Foswiki::UI::Rename

=cut

sub trashTopic {
  my $from = shift;

  my $targetWeb = $Foswiki::cfg{TrashWebName};
  my $targetTopic = $from->getPath();
  $targetTopic =~ s/[\/\.]//g;

  my $tmp = $targetTopic;
  my $n = 1;
  while (Foswiki::Func::topicExists($targetWeb, $targetTopic)) {
    $targetTopic = $tmp . $n;
    $n++;
  }

  my ($to) = Foswiki::Func::readTopic($targetWeb, $targetTopic);

  $from->move($to);
}

=begin TML

---++ StaticMethod trashAttachments($meta)

moves all attachments of a topic objects to the trash. see also Foswiki::UI::Rename

=cut

sub trashAttachments {
  my $from = shift;

  my ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment');

  foreach my $attachment ($from->find('FILEATTACHMENT')) {
    trashAttachment($from, $attachment, $trash);
  }
}

=begin TML

---++ StaticMethod trashAttachment($from, $attachment)

move a single attachment to the trash

=cut

sub trashAttachment {
  my ($from, $attachment, $trash) = @_;

  ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment')
    unless defined $trash;

  # from Foswiki::UI::Rename
  # look for a non-conflicting name in the trash web

  my $toAttachment = $attachment->{name};
  my $base = $toAttachment;
  my $ext = '';

  if ( $base =~ s/^(.*)(\..*?)$/$1_/ ) {
    $ext = $2;
  }

  my $n = 1;
  while ($trash->hasAttachment($toAttachment)) {
    $toAttachment = $base . $n . $ext;
    $n++;
  }

  $from->moveAttachment($attachment->{name}, $trash, new_name => $toAttachment);
}

=begin TML

---++ StaticMethod copyAttachments($from, $to)

moves all attachments from one topic to another.

=cut

sub copyAttachments {
  my ($from, $to) = @_;

  _writeDebug("called copyAttachments");

  foreach my $attachment ($from->find('FILEATTACHMENT')) {
    copyAttachment($from, $attachment, $to);
  }
}

=begin TML

---++ StaticMethod copyAttachment($from, $attachment, $to)

move a single attachment from one topic to another.

=cut

sub copyAttachment {
  my ($from, $attachment, $to) = @_;

  _writeDebug("called copyAttachment(attachment=$attachment->{name}, to=".$to->getPath().")");

  # NOT using copyAttachment as this will nuke revisions in the target
  # $from->copyAttachment($attachment, $to);


  my $fh = $from->openAttachment($attachment->{name}, "<");

  $to->attach(
    name => $attachment->{name},
    comment => $attachment->{comment},
    author => $attachment->{author},
    hide => $attachment->{attr} =~ /h/ ? 1:0,
    stream => $fh,
    dontlog => 1,
    notopicchange => 1,
  );

  my $toAttachment = $to->get("FILEATTACHMENT", $attachment->{name});
  $toAttachment->{attr} = $attachment->{attr} if $toAttachment;
}

=begin TML

---++ StaticMethod copyTopic($from, $to)

copies the  one topic to another. Note that
this function only copies over the top revision of the source
topic, not the entire history. It thereby creates a new revision 
at the target topic. Attachments are copied over as well. However
attachments that don't exist at the source topic anymore are removed from
the target topic.

=cut

sub copyTopic {
  my $from = shift;
  my $to = shift;

  _writeDebug("copyTopic(from=".$from->getPath().", to=".$to->getPath().")");
  my %attachmentExists = ();
  $attachmentExists{$_->{name}} = 1 foreach $from->find('FILEATTACHMENT');

  my ($trash) = Foswiki::Func::readTopic($Foswiki::cfg{TrashWebName}, 'TrashAttachment');

  foreach my $attachment ($to->find('FILEATTACHMENT')) {
    trashAttachment($to, $attachment, $trash)
      unless $attachmentExists{$attachment->{name}};
  }

  $to->text($from->text() // '');
  $to->copyFrom($from);

  my $core = Foswiki::Plugins::QMPlugin::getCore();
  my $rev = $core->saveMeta($to,
    ignorepermissions => 1,
    forcenewrevision => 1,
    @_
  );

  copyAttachments($from, $to);

  return $rev;
}

=begin TML

---++ StaticMethod moveTopic($from, $to)

this function copies the source topic to the target
and then deletes the source topic afterwards.

=cut

sub moveTopic {
  my $from = shift;
  my $to = shift;

  _writeDebug("moveTopic()");
  copyTopic($from, $to, @_);
  trashTopic($from);
}

=begin TML

---++ StaticMethod renameTopic($from, $to)

rename/moves topic from one location to another.
Note that =$to= can either be a Foswiki::Meta object
or a topic name

=cut

sub renameTopic {
  my ($from, $toOrTopic) = @_;

  _writeDebug("renameTopic()");

  my $to;

  if (ref($toOrTopic)) {
    $to = $toOrTopic;
  } else {
    my ($web, $topic) = Foswiki::Func::normalizeWebTopicName($from->web, $toOrTopic);
    $to = Foswiki::Meta->new( $Foswiki::Plugins::SESSION, $web, $topic );
  }

  # rename it
  $from->move($to);

  return $to;
}

=begin TML

---++ ObjectMethod expandAUTOINC($web, $topic) -> $topic

from Foswiki::Meta

=cut

sub expandAUTOINC {
  my ($web, $topic) = @_;

  my $session = $Foswiki::Plugins::SESSION;

  # Do not remove, keep as undocumented feature for compatibility with
  # TWiki 4.0.x: Allow for dynamic topic creation by replacing strings
  # of at least 10 x's XXXXXX with a next-in-sequence number.
  if ($topic =~ m/X{10}/) {
    my $n = 0;
    my $baseTopic = $topic;
    my $topicObject = Foswiki::Meta->new($session, $web, $baseTopic);
    $topicObject->clearLease();
    do {
      $topic = $baseTopic;
      $topic =~ s/X{10}X*/$n/e;
      $n++;
    } while (Foswiki::Func::topicExists($web, $topic));
  }

  # Allow for more flexible topic creation with sortable names.
  # See Codev.AutoIncTopicNameOnSave
  if ($topic =~ m/^(.*)AUTOINC(\d+)(.*)$/) {
    my $pre = $1;
    my $start = $2;
    my $pad = length($start);
    my $post = $3;
    my $topicObject = Foswiki::Meta->new($session, $web, $topic);
    $topicObject->clearLease();
    my $webObject = Foswiki::Meta->new($session, $web);
    my $it = $webObject->eachTopic();

    while ($it->hasNext()) {
      my $tn = $it->next();
      next unless $tn =~ m/^${pre}(\d+)${post}$/;
      $start = $1 + 1 if ($1 >= $start);
    }
    my $next = sprintf("%0${pad}d", $start);
    $topic =~ s/AUTOINC[0-9]+/$next/;
  }

  return $topic;
}

sub _writeDebug {
  return unless TRACE;
  print STDERR "QMPlugin::Utils - $_[0]\n";
}

1;
