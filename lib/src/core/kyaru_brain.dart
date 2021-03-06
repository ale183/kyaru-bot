import 'dart:async';

import 'package:dart_telegram_bot/dart_telegram_bot.dart';
import 'package:dart_telegram_bot/telegram_entities.dart';
import 'package:logging/logging.dart';

import '../../kyaru.dart';

class KyaruBrain {
  final _log = Logger('KyaruBrain');

  final KyaruDB db;
  final Bot bot;

  final modulesFunctions = <String, ModuleFunction>{};
  final coreFunctions = <String>[];
  final modules = <IModule>[];

  KyaruBrain({
    required database,
    required this.bot,
  }) : db = database;

  Future updateTelegramCommands() {
    return bot.setMyCommands(
      List<BotCommand>.of(
        modulesFunctions.values.where((m) => m.core).map(
              (m) => BotCommand(
                command: m.name,
                description: m.description!.length >= 3
                    ? m.description
                    : 'No description',
              ),
            ),
      ),
    );
  }

  Future moduleFunctionWrapper(
    ModuleFunction moduleFunction,
    Update update,
  ) async {
    try {
      await moduleFunction.function(update, null);
      _log.finer('Function ${moduleFunction.name} executed');
    } on Exception catch (e, s) {
      _log.severe('Error executing function ${moduleFunction.name}', e, s);
      await bot.sendMessage(
        db.settings.ownerId,
        'Command ${moduleFunction.name} crashed: $e',
      );
    }
  }

  void useModules(List<IModule> modules) {
    this.modules.clear();
    modules.removeWhere((module) => !module.isEnabled());
    this.modules.addAll(modules);
    for (var module in modules) {
      print(module.runtimeType);
      var moduleFunctions = module.moduleFunctions;
      for (var moduleFunction in moduleFunctions) {
        print('- ${moduleFunction.name}');
        modulesFunctions[moduleFunction.name] = moduleFunction;
        if (!moduleFunction.core) continue;
        coreFunctions.add(moduleFunction.name);
        bot.onCommand(
          moduleFunction.name,
          (bot, update) => moduleFunctionWrapper(moduleFunction, update),
        );
      }
    }
    updateTelegramCommands();
    print('------------------------------------------------');
    print('Loaded ${modulesFunctions.length} module functions');
  }

  Future<bool> readEvents(Update update) async {
    if (update.message?.newChatMembers != null) {
      var joinedMembersIds = update.message?.newChatMembers?.map((u) => u.id);
      if (joinedMembersIds?.contains(bot.id) ?? false) {
        await onNewGroup(update);
        return true;
      }
      await onNewUsers(update);
      return true;
    }

    var leftChatMember = update.message?.leftChatMember;
    if (leftChatMember != null) {
      if (leftChatMember.id == bot.id) {
        await onLeftGroup(update);
        return true;
      }
    }

    // Other events here

    return false;
  }

  Future readMessage(Update update) async {
    final text = update.message?.text;
    if (text == null) return;

    final chatId = update.message?.chat.id;
    if (chatId == null) return _log.fine('Cannot proceed if chat id is null');

    final botCommand = BotCommandParser.fromMessage(update.message!);

    final isCommandToBot = botCommand?.isToBot(bot.username!) ?? false;

    if (isCommandToBot) return onCommandToBot(update, botCommand!, chatId);

    return onTextMessage(update, chatId);
  }

  Future<bool> runInstructionFunction(
    Update update,
    Instruction instruction,
  ) async {
    if (instruction.function == null) return false;

    if (!modulesFunctions.containsKey(instruction.function)) {
      _log.warning(
        'Warning function ${instruction.function} not found in any module',
      );
      return false;
    }

    var function = instruction.function;
    if (function == null) return false;

    await modulesFunctions[function]?.function(update, instruction);
    _log.finest('Function ${instruction.function} executed');
    return !instruction.volatile;
  }

  List<Instruction> getInstructions(
    InstructionType instructionType,
    int chatId, {
    InstructionEventType? eventType,
  }) {
    return <Instruction>[
      ...db.getInstructions(instructionType, 0, eventType: eventType),
      ...db.getInstructions(instructionType, chatId, eventType: eventType),
    ];
  }

  Future<bool> execRegexInstructions(Update update, int chatId) async {
    final regexInstructions = getInstructions(InstructionType.regex, chatId);

    final text = update.message!.text;

    final validInstructions = regexInstructions.where(
      (i) {
        return i.regex! == '' ||
            (RegExp(i.regex!).firstMatch(text!) != null &&
                i.checkRequirements(update, db.settings));
      },
    ).toList();

    if (validInstructions.isEmpty) return false;

    executeVolatilePrioritized(
      validInstructions,
      update,
      runInstructionFunction,
    );
    return true;
  }

  Future<bool> execCommandInstructions(
    Update update,
    BotCommandParser botCommand,
    int chatId,
  ) async {
    final commandInstructions = getInstructions(
      InstructionType.command,
      chatId,
    );
    final validInstructions = commandInstructions.where(
      (i) {
        return i.command != null &&
            botCommand.matchesCommand(i.command!.command!) &&
            i.checkRequirements(update, db.settings);
      },
    ).toList();

    if (validInstructions.isEmpty) return false;

    executeVolatilePrioritized(
      validInstructions,
      update,
      runInstructionFunction,
    );
    return true;
  }

  Future<bool> execEventInstructions(
    Update update,
    InstructionEventType eventType,
    int chatId,
  ) async {
    final instructions = getInstructions(
      InstructionType.event,
      chatId,
      eventType: eventType,
    );
    if (instructions.isEmpty) return false;

    executeVolatilePrioritized(instructions, update, runInstructionFunction);
    return true;
  }

  Future onTextMessage(Update update, int chatId) {
    return execRegexInstructions(update, chatId);
  }

  Future onCommandToBot(
    Update update,
    BotCommandParser botCommand,
    int chatId,
  ) {
    return execCommandInstructions(update, botCommand, chatId);
  }

  Future onLeftGroup(Update update) async {}

  Future onNewGroup(Update update) {
    return execEventInstructions(
      update,
      InstructionEventType.kyaruJoined,
      update.message!.chat.id,
    );
  }

  Future onNewUsers(Update update) {
    return execEventInstructions(
      update,
      InstructionEventType.userJoined,
      update.message!.chat.id,
    );
  }

  void executeVolatilePrioritized(
    Iterable<Instruction> instructions,
    Update update,
    Function(Update, Instruction) foo,
  ) {
    for (var instruction in instructions.where((i) => i.volatile)) {
      executeGuarded(
        () => foo(update, instruction),
        'Could not execute ${instruction.command}',
      );
    }

    var notVolatileInstructions = instructions.where((i) => !i.volatile);
    if (notVolatileInstructions.isEmpty) return;
    var instruction = choose(notVolatileInstructions);
    executeGuarded(
      () => foo(update, instruction),
      'Could not execute ${instruction.command}',
    );
  }

  void executeGuarded(Function foo, String errMsg) {
    runZonedGuarded(() => foo(), (e, s) => _log.severe(errMsg, e, s));
  }
}
