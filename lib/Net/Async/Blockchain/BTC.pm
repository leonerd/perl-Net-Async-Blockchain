package Net::Async::Blockchain::BTC;

use strict;
use warnings;

our $VERSION = '0.001';

=head1 NAME

Net::Async::Blockchain::BTC - Bitcoin based subscription.

=head1 SYNOPSIS

    my $loop = IO::Async::Loop->new;

    $loop->add(
        my $btc_client = Net::Async::Blockchain::BTC->new(
            subscription_url => "tcp://127.0.0.1:28332",
            rpc_url => 'http://test:test@127.0.0.1:8332',
            rpc_timeout => 100,
        )
    );

    $btc_client->subscribe("transactions")->each(sub { print shift->{hash} })->get;

=head1 DESCRIPTION

Bitcoin subscription using ZMQ from the bitcoin based blockchain nodes

=over 4

=back

=cut

no indirect;

use Ryu::Async;
use Future::AsyncAwait;
use IO::Async::Loop;
use Math::BigFloat;
use Syntax::Keyword::Try;

use Net::Async::Blockchain::Transaction;
use Net::Async::Blockchain::Client::RPC::BTC;
use Net::Async::Blockchain::Client::ZMQ;

use parent qw(Net::Async::Blockchain);

use constant DEFAULT_CURRENCY => 'BTC';

my %subscription_dictionary = ('transactions' => 'hashblock');

sub currency_symbol : method { shift->{currency_symbol} // DEFAULT_CURRENCY }

=head2 rpc_client

Create an L<Net::Async::Blockchain::Client::RPC> instance, if it is already defined just return
the object

=over 4

=back

L<Net::Async::Blockchain::Client::RPC>

=cut

sub rpc_client : method {
    my ($self) = @_;
    return $self->{rpc_client} //= do {
        $self->add_child(my $http_client = Net::Async::Blockchain::Client::RPC::BTC->new(endpoint => $self->rpc_url));
        $self->{rpc_client} = $http_client;
        return $self->{rpc_client};
        }
}

=head2 new_zmq_client

Create a new L<Net::Async::Blockchain::Client::ZMQ> instance.

=over 4

=back

L<Net::Async::Blockchain::Client::ZMQ>

=cut

sub new_zmq_client {
    my ($self) = @_;
    $self->add_child(
        my $zmq_client = Net::Async::Blockchain::Client::ZMQ->new(
            endpoint    => $self->subscription_url,
            timeout     => $self->subscription_timeout,
            msg_timeout => $self->subscription_msg_timeout,
        ));
    return $zmq_client;
}

=head2 subscribe

Connect to the ZMQ port and subscribe to the implemented subscription:
- https://github.com/bitcoin/bitcoin/blob/master/doc/zmq.md#usage

=over 4

=item * C<subscription> string subscription name

=back

L<Ryu::Source>

=cut

sub subscribe {
    my ($self, $subscription) = @_;

    # rename the subscription to the correct blockchain node subscription
    $subscription = $subscription_dictionary{$subscription};

    die "Invalid or not implemented subscription" unless $subscription && $self->can($subscription);
    $self->new_zmq_client->subscribe($subscription)->map(async sub { await $self->$subscription(shift) })->ordered_futures;

    return $self->source;
}

=head2 hashblock

hashblock subscription

Convert and emit a L<Net::Async::Blockchain::Transaction> for the client source every new raw transaction received that
is owned by the node.

=over 4

=item * C<raw_transaction> bitcoin raw transaction

=back

=cut

async sub hashblock {
    my ($self, $block_hash) = @_;

    # 2 here means the full verbosity since we want to get the raw transactions
    my $block_response = await $self->rpc_client->get_block($block_hash, 2);

    my @transactions = map { $_->{block} = $block_response->{height}; $_ } $block_response->{tx}->@*;
    await Future->needs_all(map { $self->transform_transaction($_) } @transactions);
}

=head2 transform_transaction

Receive a decoded raw transaction and convert it to a L<Net::Async::Blockchain::Transaction> object

=over 4

=item * C<decoded_raw_transaction> the response from the command `decoderawtransaction`

=back

L<Net::Async::Blockchain::Transaction>

=cut

async sub transform_transaction {
    my ($self, $decoded_raw_transaction) = @_;

    # this will guarantee that the transaction is from our node
    # txindex must to be 0
    my $received_transaction;
    try {
        $received_transaction = await $self->rpc_client->get_transaction($decoded_raw_transaction->{txid});
    }
    catch {
        # transaction not found
        return undef;
    };

    # transaction not found, just ignore.
    return undef unless $received_transaction;

    my %addresses;
    my %category;
    my $amount = Math::BigFloat->new($received_transaction->{amount});
    my $fee    = Math::BigFloat->new($received_transaction->{fee} // 0);
    my $block  = Math::BigInt->new($decoded_raw_transaction->{block});

    # we can have multiple details when:
    # - multiple `to` addresses transactions
    # - sent and received by the same node
    for my $tx ($received_transaction->{details}->@*) {
        $addresses{$tx->{address}} = 1;
        $category{$tx->{category}} = 1;
    }
    my @addresses  = keys %addresses;
    my @categories = keys %category;

    # it can be receive, sent, internal
    # if categories has send and receive it means that is an internal transaction
    my $transaction_type = scalar @categories > 1 ? 'internal' : $categories[0];

    my $transaction = Net::Async::Blockchain::Transaction->new(
        currency     => $self->currency_symbol,
        hash         => $decoded_raw_transaction->{txid},
        block        => $block,
        from         => '',
        to           => \@addresses,
        amount       => $amount,
        fee          => $fee,
        fee_currency => $self->currency_symbol,
        type         => $transaction_type,
    );

    $self->source->emit($transaction) if $transaction;

    return 1;
}

1;
