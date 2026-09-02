//! OpenTelemetry Network Semantic Conventions
//!
//! This module defines standard network attribute names according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for network-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/general.md

const std = @import("std");

// Network attributes
pub const NETWORK_TRANSPORT = "network.transport";
pub const NETWORK_TYPE = "network.type";
pub const NETWORK_PROTOCOL_NAME = "network.protocol.name";
pub const NETWORK_PROTOCOL_VERSION = "network.protocol.version";
pub const NETWORK_CONNECTION_TYPE = "network.connection.type";
pub const NETWORK_CONNECTION_SUBTYPE = "network.connection.subtype";
pub const NETWORK_CARRIER_NAME = "network.carrier.name";
pub const NETWORK_CARRIER_MCC = "network.carrier.mcc";
pub const NETWORK_CARRIER_MNC = "network.carrier.mnc";
pub const NETWORK_CARRIER_ICC = "network.carrier.icc";

// Network peer attributes
pub const NETWORK_PEER_ADDRESS = "network.peer.address";
pub const NETWORK_PEER_PORT = "network.peer.port";

// Network local attributes
pub const NETWORK_LOCAL_ADDRESS = "network.local.address";
pub const NETWORK_LOCAL_PORT = "network.local.port";

// Network interface attributes
pub const NETWORK_INTERFACE_NAME = "network.interface.name";
pub const NETWORK_INTERFACE_ADDRESS = "network.interface.address";

// Legacy network attributes (deprecated but still used)
pub const NET_TRANSPORT = "net.transport";
pub const NET_PEER_IP = "net.peer.ip";
pub const NET_PEER_PORT = "net.peer.port";
pub const NET_PEER_NAME = "net.peer.name";
pub const NET_HOST_IP = "net.host.ip";
pub const NET_HOST_PORT = "net.host.port";
pub const NET_HOST_NAME = "net.host.name";
pub const NET_SOCK_PEER_ADDR = "net.sock.peer.addr";
pub const NET_SOCK_PEER_PORT = "net.sock.peer.port";
pub const NET_SOCK_HOST_ADDR = "net.sock.host.addr";
pub const NET_SOCK_HOST_PORT = "net.sock.host.port";
pub const NET_SOCK_FAMILY = "net.sock.family";

// Network transport values
pub const NetworkTransportValues = struct {
    pub const TCP = "tcp";
    pub const UDP = "udp";
    pub const PIPE = "pipe";
    pub const UNIX = "unix";
    pub const QUIC = "quic";
    pub const OTHER = "other";
};

// Network type values
pub const NetworkTypeValues = struct {
    pub const IPV4 = "ipv4";
    pub const IPV6 = "ipv6";
};

// Network connection type values
pub const NetworkConnectionTypeValues = struct {
    pub const WIFI = "wifi";
    pub const WIRED = "wired";
    pub const CELL = "cell";
    pub const UNAVAILABLE = "unavailable";
    pub const UNKNOWN = "unknown";
};

// Network connection subtype values
pub const NetworkConnectionSubtypeValues = struct {
    pub const GPRS = "gprs";
    pub const EDGE = "edge";
    pub const UMTS = "umts";
    pub const CDMA = "cdma";
    pub const EVDO_0 = "evdo_0";
    pub const EVDO_A = "evdo_a";
    pub const CDMA2000_1XRTT = "cdma2000_1xrtt";
    pub const HSDPA = "hsdpa";
    pub const HSUPA = "hsupa";
    pub const HSPA = "hspa";
    pub const IDEN = "iden";
    pub const EVDO_B = "evdo_b";
    pub const LTE = "lte";
    pub const EHRPD = "ehrpd";
    pub const HSPAP = "hspap";
    pub const GSM = "gsm";
    pub const TD_SCDMA = "td_scdma";
    pub const IWLAN = "iwlan";
    pub const NR = "nr";
    pub const NRNSA = "nrnsa";
    pub const LTE_CA = "lte_ca";
};

// Socket family values
pub const NetSockFamilyValues = struct {
    pub const INET = "inet";
    pub const INET6 = "inet6";
    pub const UNIX = "unix";
};

// Common network-related attributes for specific protocols
pub const NetworkProtocol = struct {
    // HTTP versions
    pub const HTTP_1_0 = "1.0";
    pub const HTTP_1_1 = "1.1";
    pub const HTTP_2 = "2";
    pub const HTTP_3 = "3";
    pub const SPDY_1 = "SPDY/1";
    pub const SPDY_2 = "SPDY/2";
    pub const SPDY_3 = "SPDY/3";
    pub const QUIC = "quic";
    
    // TLS versions
    pub const SSL_3_0 = "ssl_3.0";
    pub const TLS_1_0 = "tls_1.0";
    pub const TLS_1_1 = "tls_1.1";
    pub const TLS_1_2 = "tls_1.2";
    pub const TLS_1_3 = "tls_1.3";
};

// Network state values
pub const NetworkStateValues = struct {
    pub const CLOSE = "close";
    pub const CLOSE_WAIT = "close_wait";
    pub const CLOSING = "closing";
    pub const DELETE = "delete";
    pub const ESTABLISHED = "established";
    pub const FIN_WAIT_1 = "fin_wait_1";
    pub const FIN_WAIT_2 = "fin_wait_2";
    pub const LAST_ACK = "last_ack";
    pub const LISTEN = "listen";
    pub const SYN_RECV = "syn_recv";
    pub const SYN_SENT = "syn_sent";
    pub const TIME_WAIT = "time_wait";
};

// Helper functions for network attributes
pub fn isPrivateIPv4(address: []const u8) bool {
    // Simple check for common private IPv4 ranges
    // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    if (std.mem.startsWith(u8, address, "10.")) return true;
    if (std.mem.startsWith(u8, address, "192.168.")) return true;
    if (std.mem.startsWith(u8, address, "172.")) {
        // Check if it's in 172.16.0.0/12 range
        // This is simplified and would need proper parsing in production
        return true;
    }
    return false;
}