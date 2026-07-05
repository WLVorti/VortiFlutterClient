class MessageSearchResult {
  final String id;
  final String chatId;
  final String userId;
  final String text;
  final int createdAt;
  final String? fileId;
  final String? fileMimeType;
  final String senderName;
  final String chatName;

  MessageSearchResult({
    required this.id,
    required this.chatId,
    required this.userId,
    required this.text,
    required this.createdAt,
    this.fileId,
    this.fileMimeType,
    required this.senderName,
    required this.chatName,
  });

  factory MessageSearchResult.fromJson(Map<String, dynamic> json) {
    return MessageSearchResult(
      id: json['id'] ?? '',
      chatId: json['chatId'] ?? '',
      userId: json['userId'] ?? '',
      text: json['text'] ?? '',
      createdAt: json['createdAt'] ?? 0,
      fileId: json['fileId'],
      fileMimeType: json['fileMimeType'],
      senderName: json['senderName'] ?? '',
      chatName: json['chatName'] ?? '',
    );
  }
}

class User {
  final String id;
  final String username;
  final String? displayName;
  final String? bio;
  final String? avatarUrl;
  final int createdAt;
  final bool isOnline;
  final int? lastSeenAt;

  User({
    required this.id,
    required this.username,
    this.displayName,
    this.bio,
    this.avatarUrl,
    required this.createdAt,
    this.isOnline = false,
    this.lastSeenAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? '',
      username: json['username'] ?? '',
      displayName: json['displayName'] ?? json['username'],
      bio: json['bio'],
      avatarUrl: json['avatarUrl'],
      createdAt: json['created_at'] ?? 0,
      isOnline: json['is_online'] ?? false,
      lastSeenAt: json['last_seen_at'],
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'username': username, 'created_at': createdAt};
  }
}

class Profile {
  final String id;
  final String username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  final int createdAt;
  final int? lastSeenAt;
  final String email;
  final String tags;

  Profile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.bio,
    this.avatarUrl,
    required this.createdAt,
    this.lastSeenAt,
    this.email = '',
    this.tags = '',
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] ?? '',
      username: json['username'] ?? '',
      displayName: json['displayName'] ?? json['username'] ?? '',
      bio: json['bio'] ?? '',
      avatarUrl: json['avatarUrl'] ?? json['avatar_url'],
      createdAt: json['createdAt'] ?? json['created_at'] ?? 0,
      lastSeenAt: json['last_seen_at'],
      email: json['email'] ?? '',
      tags: json['tags'] ?? '',
    );
  }

  Profile copyWith({String? displayName, String? bio, String? avatarUrl, String? tags}) {
    return Profile(
      id: id,
      username: username,
      displayName: displayName ?? this.displayName,
      bio: bio ?? this.bio,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      createdAt: createdAt,
      email: email,
      tags: tags ?? this.tags,
    );
  }
}

class Chat {
  final String id;
  final String? name;
  final String type;
  final int createdAt;
  final String? lastMessage;
  final int? lastMessageAt;
  final String? lastMessageKeyType;
  final List<String> participants;
  final int unreadCount;
  final String? avatarUrl;
  final bool isOnline;

  Chat({
    required this.id,
    this.name,
    required this.type,
    required this.createdAt,
    this.lastMessage,
    this.lastMessageAt,
    this.lastMessageKeyType,
    required this.participants,
    this.unreadCount = 0,
    this.avatarUrl,
    this.isOnline = false,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'] ?? '',
      name: json['name'],
      type: json['type'] ?? 'direct',
      createdAt: json['created_at'] ?? 0,
      lastMessage: json['last_message'],
      lastMessageAt: json['last_message_at'],
      lastMessageKeyType: json['last_message_key_type'],
      participants: List<String>.from(json['participants'] ?? []),
      unreadCount: json['unread_count'] ?? 0,
      avatarUrl: json['avatarUrl'],
      isOnline: json['is_online'] ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'created_at': createdAt,
    'last_message': lastMessage,
    'last_message_at': lastMessageAt,
    'last_message_key_type': lastMessageKeyType,
    'participants': participants,
    'unread_count': unreadCount,
    'avatarUrl': avatarUrl,
    'is_online': isOnline,
  };
}

enum MessageStatus { sending, sent, delivered, read }

class Sticker {
  final String id;
  final String packId;
  final String imageUrl;
  final String emoji;
  final int createdAt;

  Sticker({
    required this.id,
    required this.packId,
    required this.imageUrl,
    this.emoji = '',
    required this.createdAt,
  });

  factory Sticker.fromJson(Map<String, dynamic> json) {
    return Sticker(
      id: json['id'] ?? '',
      packId: json['packId'] ?? json['pack_id'] ?? '',
      imageUrl: json['imageUrl'] ?? json['image_url'] ?? '',
      emoji: json['emoji'] ?? '',
      createdAt: json['createdAt'] ?? json['created_at'] ?? 0,
    );
  }
}

class StickerPack {
  final String id;
  final String name;
  final String authorId;
  final String? coverUrl;
  final int stickerCount;
  final int createdAt;
  final List<Sticker>? stickers;

  StickerPack({
    required this.id,
    required this.name,
    required this.authorId,
    this.coverUrl,
    this.stickerCount = 0,
    required this.createdAt,
    this.stickers,
  });

  factory StickerPack.fromJson(Map<String, dynamic> json) {
    return StickerPack(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      authorId: json['authorId'] ?? json['author_id'] ?? '',
      coverUrl: json['coverUrl'] ?? json['cover_url'],
      stickerCount: json['stickerCount'] ?? json['sticker_count'] ?? 0,
      createdAt: json['createdAt'] ?? json['created_at'] ?? 0,
      stickers: json['stickers'] != null
          ? (json['stickers'] as List).map((s) => Sticker.fromJson(s)).toList()
          : null,
    );
  }
}

class Message {
  final String id;
  final String chatId;
  final String userId;
  final String text;
  final String? replyTo;
  final String? replyText;
  final String? replyUsername;
  final String? fileId;
  final String? fileMimeType;
  final String? stickerId;
  final String? stickerImageUrl;
  final String? stickerEmoji;
  final String? stickerPackId;
  final int createdAt;
  final bool isDeleted;
  final bool isEdited;
  final String? editedText;
  final MessageStatus status;
  final String? keyType;
  final String? plainText;

  Message({
    required this.id,
    required this.chatId,
    required this.userId,
    required this.text,
    this.replyTo,
    this.replyText,
    this.replyUsername,
    this.fileId,
    this.fileMimeType,
    this.stickerId,
    this.stickerImageUrl,
    this.stickerEmoji,
    this.stickerPackId,
    required this.createdAt,
    this.isDeleted = false,
    this.isEdited = false,
    this.editedText,
    this.status = MessageStatus.sent,
    this.keyType,
    this.plainText,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    MessageStatus parseStatus(String? s) {
      switch (s) {
        case 'read':
          return MessageStatus.read;
        case 'delivered':
          return MessageStatus.delivered;
        default:
          return MessageStatus.sent;
      }
    }

    final replyData = json['reply'] as Map<String, dynamic>?;

    return Message(
      id: json['id'] ?? '',
      chatId: json['chat_id'] ?? '',
      userId: json['user_id'] ?? '',
      text: json['text'] ?? '',
      replyTo: json['reply_to'] ?? replyData?['replyId'],
      replyText: replyData?['replyText'],
      replyUsername: replyData?['replyUser'],
      fileId: json['file_id'],
      fileMimeType: json['file_mime_type'],
      stickerId: json['sticker_id'] ?? json['stickerId'],
      stickerImageUrl: json['sticker_image_url'] ?? json['stickerImageUrl'],
      stickerEmoji: json['sticker_emoji'] ?? json['stickerEmoji'],
      stickerPackId: json['sticker_pack_id'] ?? json['stickerPackId'],
      createdAt: json['created_at'] ?? 0,
      isDeleted: json['is_deleted'] ?? false,
      isEdited: json['is_edited'] ?? false,
      editedText: json['edited_text'],
      status: parseStatus(json['status']),
      keyType: json['key_type'],
      plainText: json['plain_text'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chat_id': chatId,
      'user_id': userId,
      'text': text,
      'reply_to': replyTo,
      'reply_text': replyText,
      'reply_username': replyUsername,
      'file_id': fileId,
      'file_mime_type': fileMimeType,
      'sticker_id': stickerId,
      'sticker_image_url': stickerImageUrl,
      'sticker_emoji': stickerEmoji,
      'sticker_pack_id': stickerPackId,
      'created_at': createdAt,
      'is_deleted': isDeleted,
      'is_edited': isEdited,
      'edited_text': editedText,
      'status': status.name,
      'key_type': keyType,
      'plain_text': plainText,
    };
  }

  Message copyWith({
    String? text,
    bool? isDeleted,
    bool? isEdited,
    String? editedText,
    String? replyText,
    MessageStatus? status,
    String? plainText,
  }) {
    return Message(
      id: id,
      chatId: chatId,
      userId: userId,
      text: text ?? this.text,
      replyTo: replyTo,
      replyText: replyText ?? this.replyText,
      replyUsername: replyUsername,
      fileId: fileId,
      stickerId: stickerId,
      stickerImageUrl: stickerImageUrl,
      stickerEmoji: stickerEmoji,
      stickerPackId: stickerPackId,
      createdAt: createdAt,
      isDeleted: isDeleted ?? this.isDeleted,
      isEdited: isEdited ?? this.isEdited,
      editedText: editedText ?? this.editedText,
      status: status ?? this.status,
      keyType: keyType ?? this.keyType,
      plainText: plainText ?? this.plainText,
    );
  }
}
