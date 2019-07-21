use v5.24.0;
use warnings;
package LiquidPlanner::Client;
# ABSTRACT: a so-so, asynchronous API client for LiquidPlanner

use Moose;
use utf8;

use experimental qw(signatures lexical_subs);
use namespace::clean;
use JSON::MaybeXS;
use DateTime;
use URI::Find;
use URI::QueryParam;

my $JSON = JSON::MaybeXS->new->utf8;

has workspace_id => (
  is  => 'ro',
  isa => 'Int',
  required => 1,
);

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has logger_callback => (
  required => 1,
  traits   => [ 'Code' ],
  required => 1,
  handles  => { 'logger' => 'execute_method' },
);

sub log       { (shift)->logger->log(@_) }
sub log_debug { (shift)->logger->log_debug(@_) }

sub _lp_base_uri ($self) {
  return "https://app.liquidplanner.com/api/workspaces/" . $self->workspace_id;
}

has http_client => (
  is => 'ro',
  required => 1,
);

sub http_request ($self, $method, $path, $json = undef) {
  my $uri = $self->_lp_base_uri . $path;

  my $res_f = $self->http_client->do_request(
    method => $method,
    uri    => $uri,
    headers => [ Authorization => $self->auth_token ],
    ($json ? (content => $json, content_type => 'application/json') : ()),
  );

  $res_f->then(sub ($res) {
    unless ($res->is_success) {
      $self->log([
        "error with %s %s: %s",
        $method,
        $uri,
        $res->as_string,
      ]);

      return Future->fail($res);
    }

    return Future->done($JSON->decode($res->decoded_content));
  });
}

sub wait_named ($self, $href) {
  Future->wait_all(values %$href)->then(sub {
    Future->done($href);
  });
}

my %DEFAULT_INCLUDE = (comments => 1, links => 1, tags => 1);

my sub _includify ($query, $include) {
  my %include = (
    %DEFAULT_INCLUDE,
    ($include ? %$include : ()),
  );

  my @include = sort grep {; $include{$_} } keys %include;
  $query->query_param(include => join q{,}, @include) if @include;
  return;
}

sub timesheet_entries ($self, $arg) {
  for (qw(start_date end_date)) {
    return Future->fail("no $_ provided") unless $arg->{$_};
  }

  my $query = URI->new("/timesheet_entries");
  $query->query_param(start_date => $arg->{start_date});
  $query->query_param(end_date   => $arg->{end_date});

  $query->query_param(member_id => $arg->{member_ids}[0])
    if $arg->{member_ids}->@* == 1;

  my %want_member_id;
  %want_member_id = map {; $_ => 1 } $arg->{member_ids}->@*
    if $arg->{member_ids};

  my $get = $self->http_request(GET => $query);
  $get->then(sub ($data) {
    if (%want_member_id) {
      @$data = grep {; $want_member_id{$_->{member_id}} } @$data;
    }
    return Future->done($data);
  });
}

sub get_clients ($self) {
  $self->http_request(GET => "/clients");
}

sub get_item ($self, $item_id, $arg = {}) {
  my $query = URI->new("/treeitems/?filter[]=id=$item_id");
  _includify($query, $arg->{include});

  $self->http_request(GET => $query)
       ->then(sub ($data) { Future->done($data->[0]) });
}

sub update_item ($self, $item_id, $payload) {
  return $self->http_put(
    "/tasks/$item_id",
    content_type => 'application/json',
    content => $JSON->encode($payload),
  );
}

has single_activity_id => (
  is  => 'ro',
  isa => 'Int',
  predicate => 'has_single_activity_id',
);

sub get_activity_id ($self, $task_or_id, $member_id = undef) {
  return $self->has_single_activity_id
         ? Future->done($self->single_activity_id)
         : Future->fail("get_activity_id not really implemented");
}

sub my_timers ($self) {
  return $self->http_request(GET => "/my_timers");
}

sub my_running_timer ($self) {
  # Treat as impossible, for now, >1 running timer. -- rjbs, 2018-06-26
  $self->my_timers->then(sub ($data) {
    my ($timer) = grep {; $_->{running} } @$data;
    return $timer ? Future->done( LiquidPlanner::Client::Timer->new($timer) )
                  : Future->done;
  });
}

sub query_items ($self, $arg) {
  my $query = URI->new("/treeitems" . ($arg->{in} ? "/$arg->{in}" : q{}));

  _includify($query, $arg->{include});

  for my $flag (keys $arg->{flags}->%*) {
    $query->query_param($flag => $arg->{flags}{$flag});
  }

  my %type;
  for my $filter ($arg->{filters}->@*) {
    my $string = join q{ }, @$filter;

    # This is utter horsecrap.
    # /treeitems?filter[]=is_done+is+false&filter[]=item_type+is+Task <- slower
    #     /tasks?filter[]=is_done+is+false&filter[]=item_type+is+Task <- slower
    #     /tasks?filter[]=is_done+is+false                            <- faster
    if (@$filter == 3 && $filter->[0] eq 'item_type' && $filter->[1] eq 'is') {
      $type{$filter->[2]} = 1;
    } else {
      $query->query_param_append('filter[]' => $string);
    }
  }

  my ($type, $nok) = keys %type;
  if ($type && ! $nok && ($type eq 'Project' or $type eq 'Task')) {
    $query =~ s[\A/treeitems][/\l${type}s];
  } elsif ($type) {
    for my $key (keys %type) {
      $query->query_param_append('filter[]' => "item_type is $key");
    }
  }

  return $self->http_request(GET => "$query");
}

sub upcoming_task_groups_for_member_id ($self, $member_id, $limit = 200) {
  return $self->http_request(GET => "/upcoming_tasks?limit=$limit&member_id=$member_id",
  );
}

sub start_timer_for_task_id ($self, $task_id) {
  my $start_res = $self->http_request(POST => "/tasks/$task_id/timer/start", '{}');
  $start_res->then(sub ($data) {
    return Future->fail("new timer not running?!") unless $data->{running};
    return Future->done($data);
  });
}

sub stop_timer_for_task_id ($self, $task_id) {
  return $self->http_request(POST => "/tasks/$task_id/timer/stop", '{}');
}

sub clear_timer_for_task_id ($self, $task_id) {
  return $self->http_request(POST => "/tasks/$task_id/timer/clear", '{}');
}

sub track_time ($self, $arg) {
  Carp::confess("no task_id")     unless $arg->{task_id};
  Carp::confess("no activity_id") unless $arg->{activity_id};
  Carp::confess("no work")        unless defined $arg->{work};
  Carp::confess("no member_id")   unless $arg->{member_id};

  my $comment = $arg->{comment};

  if (defined $comment) {
    # Linkify URL-looking things
    my $finder = URI::Find->new(sub ($uri, $orig_text) {
      return qq{<a href="$orig_text">$orig_text</a>};
    });

    $finder->find(\$comment);
  }

  my $res_f = $self->http_request(
    POST => "/tasks/$arg->{task_id}/track_time",
    $JSON->encode({
      activity_id => $arg->{activity_id},
      member_id => $arg->{member_id},
      work      => $arg->{work},
      reduce_estimate => \1,

      (defined $comment ? (comment => $comment) : ()),
    }),
  );

  $res_f->then_with_f(sub ($f, $task) {
    my ($assignment) = grep {; $_->{person_id} == $arg->{member_id} }
                       $task->{assignments}->@*;

    die "WHERE IS MY ASSIGNMENT" unless $assignment;

    if ($arg->{done} xor $assignment->{is_done}) {
      $f = $f->then(sub {
        return $self->http_request(
          POST => "/tasks/$arg->{task_id}/update_assignment",
          $JSON->encode({
            assignment_id => $assignment->{id},
            is_done       => ($arg->{done} ? \1 : \0),
          }),
        );
      });
    }

    return $f->then(sub {
      Future->done({
        item_id => $arg->{task_id},
        work    => $arg->{work},
        assignment_id => $assignment->{id},
      });
    });
  });
}

sub create_task ($self, $task) {
  return $self->http_request(
    POST => "/tasks",
    $JSON->encode($task),
  );
}

# get current iteration data

sub todo_items ($self) {
  return $self->http_request(GET => "/todo_items");
}

sub create_todo_item ($self, $todo) {
  return $self->http_request(
    POST => "/todo_items",
    $JSON->encode({ todo_item => $todo }),
  );
}

sub current_iteration ($self) {
  my $helper = LiquidPlanner::Client::IterationHelper->new({ lpc => $self });

  my $iter  = $helper->current_iteration;
  my $pkg_f = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_f->await->is_done;

  return {
    %$iter,
    package => $pkg_f->get,
  };
}

sub iteration_by_number ($self, $n) {
  my $helper = LiquidPlanner::Client::IterationHelper->new({ lpc => $self });

  my $iter  = $helper->iteration_by_number($n);
  my $pkg_f = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_f->await->is_done;

  return {
    %$iter,
    package => $pkg_f->get,
  };
}

sub iteration_relative_to_current ($self, $delta_n) {
  my $helper = LiquidPlanner::Client::IterationHelper->new({ lpc => $self });

  my $iter  = $helper->iteration_relative_to_current($delta_n);
  my $pkg_f = $helper->package_for_iteration_number($iter->{number});

  return unless $pkg_f->await->is_done;

  return {
    %$iter,
    package => $pkg_f->get,
  };
}

package LiquidPlanner::Client::Timer {

  use Moose;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);
  use Time::Duration;

  for my $prop (qw(
    total_time
    person_id
    running
    id
    item_id
    type
    running_time
  )) {
    has $prop => (is => 'ro');
  }

  # Total time is a *lie*. It's undef if the timer has never
  # been stopped/resumed. If it has been resumed, it's only
  # the previous time, not including current running time...
  sub real_total_time ($self) {
    return ($self->total_time // 0) + $self->running_time;
  }

  for my $prop (qw(
    real_total_time
    total_time
    running_time
  )) {
    no strict 'refs';

    my $sub = $prop . "_duration";

    *$sub = sub ($self) {
      return concise( duration( $self->$prop * 3600 ) );
    };
  }
}

package LiquidPlanner::Client::IterationHelper {

  use Moose;
  use MooseX::StrictConstructor;
  use namespace::autoclean;
  use experimental qw(signatures lexical_subs);

  has lpc => (is => 'ro', required => 1, weak_ref => 1);

  # This is stupid hard-coding, but it eliminates much, much stupider
  # hard-coding. -- rjbs, 2019-02-27
  my @Sync_Points = (
    [ '2016-12-31' => '200' ],
    [ '2017-12-24' => '224' ],
  );

  sub iteration_by_number ($self, $n) {
    my @candidates = grep {; $_->[1] <= $n } @Sync_Points;
    die "can't compute iteration #$n" unless @candidates;

    my ($sync_start, $sync_number) = @{ $candidates[-1] };

    my (@ymd) = split /-/, $sync_start;
    my $sync_start_dt = DateTime->new(
      year  => $ymd[0],
      month => $ymd[1],
      day   => $ymd[2],
    );

    my $iters = $n - $sync_number;

    my $i_start = $sync_start_dt + DateTime::Duration->new(days => $iters * 14);
    my $i_end   = $i_start       + DateTime::Duration->new(days => 13);

    return {
      number => $n,
      start  => $i_start->ymd,
      end    => $i_end->ymd,
    };
  }

  sub iteration_on_date ($self, $datetime) {
    if (! ref $datetime) {
      state $strp = DateTime::Format::Strptime->new(pattern => '%F');
      my $obj = $strp->parse_datetime($datetime);
      die qq{can't understand date string "$datetime"} unless $obj;
      $datetime = $obj;
    }

    my $ymd = $datetime->ymd('-');
    my @candidates = grep {; $_->[0] le $ymd } @Sync_Points;
    die "can't compute iteration for $ymd" unless @candidates;

    my ($sync_start, $sync_number) = @{ $candidates[-1] };

    my (@ymd) = split /-/, $sync_start;
    my $sync_start_dt = DateTime->new(
      year  => $ymd[0],
      month => $ymd[1],
      day   => $ymd[2],
    );

    my $days = int($datetime->jd) - int($sync_start_dt->jd);
    my $fns = int $days / 14;

    my $i_start = $sync_start_dt + DateTime::Duration->new(days => $fns * 14);
    my $i_end   = $i_start       + DateTime::Duration->new(days => 13);

    return {
      number => $sync_number + $fns,
      start  => $i_start->ymd,
      end    => $i_end->ymd,
    };
  }

  sub current_iteration ($self) {
    my $iter = $self->iteration_on_date(DateTime->now);
    return $iter;
  }

  sub iteration_relative_to_current ($self, $delta_n) {
    return $self->iteration_on_date(
      DateTime->now->add(weeks => 2 * $delta_n)
    );
  }

  sub package_for_iteration_number ($self, $n) {
    # We could cache this, but the lifecycle of IterationHelper and LPC objects
    # is not really reliable and we'd end up with duplicates and it would be
    # stupid. -- rjbs, 2019-02-27
    my $query_f = $self->lpc->query_items({
      # in => $root_id
      flags => {
        depth => -1,
        flat  => 1,
      },
      filters => [
        [ name   => 'starts_with',  "#$n" ],
      ],
    });

    return $query_f->then(sub ($data) { $data->[0] });
  }

  sub package_for_current_iteration ($self) {
    state $iter = $self->iteration_on_date(DateTime->now);
    return $self->package_for_iteration_number($iter->{number});
  }
}

sub new_standalone ($class, @rest) {
  LiquidPlanner::Client::Standalone->new(@rest);
}

package LiquidPlanner::Client::Standalone {

  use Moose;
  extends 'LiquidPlanner::Client';

  has loop => (
    is => 'ro',
    default => sub {
      require IO::Async::Loop;
      IO::Async::Loop->new;
    },
  );

  has '+http_client' => (
    lazy => 1,
    default => sub {
      require Net::Async::HTTP;
      my $http_client = Net::Async::HTTP->new(max_connections_per_host => 5);
      $_[0]->loop->add($http_client);
      return $http_client;
    },
  );

  no Moose;
  __PACKAGE__->meta->make_immutable;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
