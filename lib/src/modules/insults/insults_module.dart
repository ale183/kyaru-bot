import 'dart:async';

import 'package:dart_telegram_bot/telegram_entities.dart';

import '../../../kyaru.dart';
import 'entities/insults_client.dart';

class InsultsModule implements IModule {
  final Kyaru _kyaru;
  final InsultsClient insultsClient = InsultsClient();

  late List<ModuleFunction> _moduleFunctions;

  InsultsModule(this._kyaru) {
    _moduleFunctions = [
      ModuleFunction(insult, 'Sends a random insult', 'insult', core: true),
    ];
  }

  @override
  List<ModuleFunction> get moduleFunctions => _moduleFunctions;

  @override
  bool isEnabled() => true;

  Future insult(Update update, _) async {
    var insult = await insultsClient.getInsult();
    return _kyaru.reply(
      update,
      '$insult',
      quoteQuoted: update.message!.replyToMessage != null,
    );
  }
}
