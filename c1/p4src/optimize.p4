/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<3>  res;
    bit<3>  ecn;
    bit<6>  ctrl;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

struct metadata {
    bit<14> ecmp_select;
}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            6: parse_tcp;
            default: accept;
        }
    }
    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action nop() { }
    action drop() {
        mark_to_drop();
    }
    action set_ecmp_select(bit<16> ecmp_base, bit<32> ecmp_count) {
        hash(meta.ecmp_select,
        HashAlgorithm.crc16,
        ecmp_base,
        { hdr.ipv4.srcAddr,
          hdr.ipv4.dstAddr,
          hdr.ipv4.protocol,
          hdr.tcp.srcPort,
          hdr.tcp.dstPort },
        ecmp_count);
    }
    action set_nhop(bit<48> nhop_dmac, bit<32> nhop_ipv4, bit<9> port) {
        hdr.ethernet.dstAddr = nhop_dmac;
        hdr.ipv4.dstAddr = nhop_ipv4;
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    action debug() {
        standard_metadata.egress_spec = 2;
    }

    bit<16> ecmp_base_tmp=16w0;
    bit<32> ecmp_count_tmp=32w0;
    // bit<32> tid = 32w0;
    bit<32> aid = 32w0;
    bit<32> did = 32w0;
    action _drop() {
        mark_to_drop();
    }
    action composed_a(inout bit<32> a, inout bit<32> d, bit<32> a1, bit<32> d1, bit<16> ecmp_base, bit<32> ecmp_count) {
        // t = t1; // target table id
        a = a1; // target action id
        d = d1; // default actions
        ecmp_base_tmp = ecmp_base;
        ecmp_count_tmp = ecmp_count;
    }
    table composed_t {
        actions = {
            composed_a(aid, did); _drop;
        }
        key = {
            standard_metadata.ingress_port: ternary;
            hdr.ipv4.srcAddr              : ternary;
            hdr.ipv4.dstAddr              : ternary;
            hdr.tcp.srcPort               : ternary;
            hdr.tcp.dstPort               : ternary;
        }
    }
    
    table ecmp_nhop {
        key = {
            meta.ecmp_select: exact;
        }
        actions = {
            drop;
            set_nhop;
        }
        size = 2;
    }
    apply {
        if (hdr.ipv4.isValid() && hdr.ipv4.ttl > 0) { // here we remove "hdr.tcp.isValid()" for measuring RTT
            if (!composed_t.apply().hit) {
                mark_to_drop();
                exit;
            }

            // table1
            bool ipv4_tcp_acl_hit = false;
            if (((aid>>0)&32w1) == 32w1) { 
                nop();
                if (((did>>0)&32w1) != 32w1) {
                    ipv4_tcp_acl_hit = true;
                }
            } else if (((aid>>1)&32w1) == 32w1) { 
                drop();
                if (((did>>1)&32w1) != 32w1) {
                    ipv4_tcp_acl_hit = true;
                }
            }

            // table2
            if (ipv4_tcp_acl_hit) { 
                if (((aid>>2)&32w1) == 32w1) { 
                    drop();
                } else 
                if (((aid>>3)&32w1) == 32w1) { 
                    set_ecmp_select(ecmp_base_tmp, ecmp_count_tmp);
                }

                ecmp_nhop.apply();
            }
        }
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    
    action rewrite_mac(bit<48> smac) {
        hdr.ethernet.srcAddr = smac;
    }
    action drop() {
        mark_to_drop();
    }
    table send_frame {
        key = {
            standard_metadata.egress_port: exact;
        }
        actions = {
            rewrite_mac;
            drop;
        }
        size = 256;
    }
    apply {
        send_frame.apply();
    }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
     apply {
    update_checksum(
        hdr.ipv4.isValid(),
            { hdr.ipv4.version,
          hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
    }
}

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
