// This is a generated file - do not edit.
//
// Generated from edge_action.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use actionChunkDescriptor instead')
const ActionChunk$json = {
  '1': 'ActionChunk',
  '2': [
    {'1': 'frame_id', '3': 1, '4': 1, '5': 4, '10': 'frameId'},
    {'1': 'capture_time_ns', '3': 2, '4': 1, '5': 4, '10': 'captureTimeNs'},
    {'1': 'num_tokens', '3': 3, '4': 1, '5': 13, '10': 'numTokens'},
    {'1': 'embed_dim', '3': 4, '4': 1, '5': 13, '10': 'embedDim'},
    {'1': 'values_fp16', '3': 5, '4': 1, '5': 12, '10': 'valuesFp16'},
    {'1': 'scaled_to_m', '3': 6, '4': 1, '5': 8, '10': 'scaledToM'},
    {'1': 'goal_id', '3': 7, '4': 1, '5': 9, '10': 'goalId'},
    {'1': 'from_model', '3': 8, '4': 1, '5': 8, '10': 'fromModel'},
  ],
};

/// Descriptor for `ActionChunk`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List actionChunkDescriptor = $convert.base64Decode(
    'CgtBY3Rpb25DaHVuaxIZCghmcmFtZV9pZBgBIAEoBFIHZnJhbWVJZBImCg9jYXB0dXJlX3RpbW'
    'VfbnMYAiABKARSDWNhcHR1cmVUaW1lTnMSHQoKbnVtX3Rva2VucxgDIAEoDVIJbnVtVG9rZW5z'
    'EhsKCWVtYmVkX2RpbRgEIAEoDVIIZW1iZWREaW0SHwoLdmFsdWVzX2ZwMTYYBSABKAxSCnZhbH'
    'Vlc0ZwMTYSHgoLc2NhbGVkX3RvX20YBiABKAhSCXNjYWxlZFRvTRIXCgdnb2FsX2lkGAcgASgJ'
    'UgZnb2FsSWQSHQoKZnJvbV9tb2RlbBgIIAEoCFIJZnJvbU1vZGVs');

@$core.Deprecated('Use controlAckDescriptor instead')
const ControlAck$json = {
  '1': 'ControlAck',
  '2': [
    {'1': 'frame_id', '3': 1, '4': 1, '5': 4, '10': 'frameId'},
    {'1': 'following', '3': 2, '4': 1, '5': 8, '10': 'following'},
    {'1': 'status', '3': 3, '4': 1, '5': 9, '10': 'status'},
  ],
};

/// Descriptor for `ControlAck`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List controlAckDescriptor = $convert.base64Decode(
    'CgpDb250cm9sQWNrEhkKCGZyYW1lX2lkGAEgASgEUgdmcmFtZUlkEhwKCWZvbGxvd2luZxgCIA'
    'EoCFIJZm9sbG93aW5nEhYKBnN0YXR1cxgDIAEoCVIGc3RhdHVz');
