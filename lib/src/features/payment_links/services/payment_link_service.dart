import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../main.dart' show log;
import '../../../core/storage/wallet_paths.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/app_security_provider.dart';
import '../../../providers/rpc_endpoint_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../rust/api/sync.dart' as rust_sync;
import '../../../rust/api/wallet.dart' as rust_wallet;
import '../../send/services/sapling_params.dart';
import '../models/vizor_payment_link.dart';

final paymentLinkServiceProvider = Provider<PaymentLinkService>(
  PaymentLinkService.new,
);

class PaymentLinkClaimSession {
  const PaymentLinkClaimSession({
    required this.link,
    required this.directory,
    required this.dbPath,
    required this.accountUuid,
    required this.totalZatoshi,
    required this.claimableZatoshi,
    required this.feeZatoshi,
  });

  final VizorPaymentLink link;
  final Directory directory;
  final String dbPath;
  final String accountUuid;
  final BigInt totalZatoshi;
  final BigInt claimableZatoshi;
  final BigInt feeZatoshi;

  bool get canClaim => claimableZatoshi > BigInt.zero;
}

class PaymentLinkService {
  PaymentLinkService(this._ref);

  final Ref _ref;

  Future<VizorPaymentLink> createFundedLink({
    required BigInt amountZatoshi,
    required String sourceAccountUuid,
  }) async {
    if (sourceAccountUuid.isEmpty) {
      throw StateError('No active account.');
    }

    final endpoint = _ref.read(rpcEndpointProvider);
    final paymentAccount = await rust_wallet.previewNewSoftwareAccount(
      network: endpoint.networkName,
    );
    final ephemeralAddress = paymentAccount.unifiedAddress;
    if (ephemeralAddress.isEmpty) {
      throw StateError('Payment link account was created without an address.');
    }

    final birthdayHeight = await rust_wallet.getLatestBlockHeight(
      lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
    );

    try {
      await _sendShielded(
        fromAccountUuid: sourceAccountUuid,
        toAddress: ephemeralAddress,
        amountZatoshi: amountZatoshi,
        memo: null,
      );

      unawaited(_ref.read(syncProvider.notifier).refreshAfterSend());
      return VizorPaymentLink(
        network: endpoint.networkName,
        address: ephemeralAddress,
        amountZatoshi: amountZatoshi,
        mnemonic: paymentAccount.mnemonic,
        birthdayHeight: birthdayHeight.toInt(),
        label: 'Payment link',
        createdAt: DateTime.now(),
      );
    } finally {
      final activeUuid = _ref.read(accountProvider).value?.activeAccountUuid;
      if (activeUuid != sourceAccountUuid) {
        await _ref
            .read(accountProvider.notifier)
            .switchAccount(sourceAccountUuid);
      }
    }
  }

  Future<PaymentLinkClaimSession> prepareClaim(VizorPaymentLink link) async {
    final receiverState = _ref.read(accountProvider).value;
    final receiverAddress = receiverState?.activeAddress;
    if (receiverState?.activeAccountUuid == null ||
        receiverAddress == null ||
        receiverAddress.isEmpty) {
      throw StateError('No active receive account.');
    }
    await _requireShieldedAddress(receiverAddress);
    final endpoint = _ref.read(rpcEndpointProvider);
    if (link.network != endpoint.networkName) {
      throw StateError(
        'Payment link is for ${link.network}, but this wallet is using '
        '${endpoint.networkName}.',
      );
    }

    final tempWallet = await _createTemporaryWalletDb();
    try {
      final imported = await rust_wallet.importWallet(
        mnemonic: link.mnemonic,
        birthdayHeight: BigInt.from(link.birthdayHeight),
        network: endpoint.networkName,
        dbPath: tempWallet.dbPath,
        accountName: 'Payment link claim',
      );

      await _runBlockingSync(dbPath: tempWallet.dbPath);
      final balance = await rust_sync.getBalance(
        dbPath: tempWallet.dbPath,
        network: endpoint.networkName,
        accountUuid: imported.accountUuid,
      );
      var claimableZatoshi = BigInt.zero;
      var feeZatoshi = BigInt.zero;
      try {
        final estimate = await rust_sync.estimateSendMaxMinConfirmations(
          dbPath: tempWallet.dbPath,
          network: endpoint.networkName,
          accountUuid: imported.accountUuid,
          toAddress: receiverAddress,
        );
        claimableZatoshi = estimate.amountZatoshi;
        feeZatoshi = estimate.feeZatoshi;
      } catch (e) {
        final message = e.toString().toLowerCase();
        if (!message.contains('insufficient balance')) {
          rethrow;
        }
      }

      return PaymentLinkClaimSession(
        link: link,
        directory: tempWallet.directory,
        dbPath: tempWallet.dbPath,
        accountUuid: imported.accountUuid,
        totalZatoshi: balance.total,
        claimableZatoshi: claimableZatoshi,
        feeZatoshi: feeZatoshi,
      );
    } catch (_) {
      await _deleteTemporaryWalletDb(tempWallet.directory);
      rethrow;
    }
  }

  Future<String> claimPreparedLink(PaymentLinkClaimSession session) async {
    final receiverState = _ref.read(accountProvider).value;
    final receiverAddress = receiverState?.activeAddress;
    if (receiverState?.activeAccountUuid == null ||
        receiverAddress == null ||
        receiverAddress.isEmpty) {
      throw StateError('No active receive account.');
    }
    await _requireShieldedAddress(receiverAddress);
    if (!session.canClaim) {
      throw StateError('Payment link has no spendable shielded balance yet.');
    }

    try {
      final estimate = await rust_sync.estimateSendMaxMinConfirmations(
        dbPath: session.dbPath,
        network: _ref.read(rpcEndpointProvider).networkName,
        accountUuid: session.accountUuid,
        toAddress: receiverAddress,
      );
      if (estimate.amountZatoshi <= BigInt.zero) {
        throw StateError('Payment link has no spendable shielded balance yet.');
      }

      final txids = await _sendShielded(
        dbPath: session.dbPath,
        fromAccountUuid: session.accountUuid,
        toAddress: receiverAddress,
        amountZatoshi: estimate.amountZatoshi,
        memo: null,
        mnemonic: session.link.mnemonic,
        useMinConfirmations: true,
      );
      unawaited(_ref.read(syncProvider.notifier).refreshAfterSend());
      return txids;
    } finally {
      await discardClaimSession(session);
    }
  }

  Future<String> claimLink(VizorPaymentLink link) async {
    final session = await prepareClaim(link);
    return claimPreparedLink(session);
  }

  Future<void> discardClaimSession(PaymentLinkClaimSession session) =>
      _deleteTemporaryWalletDb(session.directory);

  Future<String> _sendShielded({
    String? dbPath,
    required String fromAccountUuid,
    required String toAddress,
    required BigInt amountZatoshi,
    String? memo,
    String? mnemonic,
    bool useMinConfirmations = false,
  }) async {
    await _requireShieldedAddress(toAddress);
    final walletDbPath = dbPath ?? await getWalletDbPath();
    final endpoint = _ref.read(rpcEndpointProvider);
    final sendFlowId = _newSendFlowId();
    final proposal = useMinConfirmations
        ? await rust_sync.proposeSendMinConfirmations(
            dbPath: walletDbPath,
            network: endpoint.networkName,
            accountUuid: fromAccountUuid,
            sendFlowId: sendFlowId,
            toAddress: toAddress,
            amountZatoshi: amountZatoshi,
            memo: memo,
          )
        : await rust_sync.proposeSend(
            dbPath: walletDbPath,
            network: endpoint.networkName,
            accountUuid: fromAccountUuid,
            sendFlowId: sendFlowId,
            toAddress: toAddress,
            amountZatoshi: amountZatoshi,
            memo: memo,
          );

    try {
      final result = await _executeProposal(
        dbPath: walletDbPath,
        lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
        accountUuid: fromAccountUuid,
        proposalId: proposal.proposalId,
        sendFlowId: sendFlowId,
        needsSaplingParams: proposal.needsSaplingParams,
        mnemonic: mnemonic,
      );
      if (result.status != 'broadcasted') {
        throw StateError(result.message ?? 'Transaction was not broadcast.');
      }
      return result.txids;
    } catch (e) {
      try {
        await rust_sync.discardProposal(
          proposalId: proposal.proposalId,
          sendFlowId: sendFlowId,
        );
      } catch (discardError) {
        log('PaymentLinkService: discardProposal failed: $discardError');
      }
      rethrow;
    }
  }

  Future<rust_sync.ExecuteProposalResult> _executeProposal({
    required String dbPath,
    required String lightwalletdUrl,
    required String accountUuid,
    required BigInt proposalId,
    required String sendFlowId,
    required bool needsSaplingParams,
    String? mnemonic,
  }) async {
    var saplingParams = await loadSaplingParamsStatus();
    if (needsSaplingParams && !saplingParams.complete) {
      await downloadMissingSaplingParams(
        saplingParams,
        log: (message) => log('PaymentLinkService: $message'),
      );
      saplingParams = await loadSaplingParamsStatus();
    }

    if (Platform.isMacOS && mnemonic == null) {
      final password = _ref
          .read(appSecurityProvider.notifier)
          .requireSessionPasswordForNativeSecretUse();
      return rust_sync.executeProposalWithMacosStoredMnemonic(
        dbPath: dbPath,
        lightwalletdUrl: lightwalletdUrl,
        proposalId: proposalId,
        sendFlowId: sendFlowId,
        password: password,
        spendParamsPath: needsSaplingParams ? saplingParams.spendPath : null,
        outputParamsPath: needsSaplingParams ? saplingParams.outputPath : null,
      );
    }

    final mnemonicBytes = mnemonic == null
        ? await _ref
              .read(accountProvider.notifier)
              .getMnemonicBytesForAccount(accountUuid)
        : Uint8List.fromList(mnemonic.codeUnits);
    if (mnemonicBytes == null || mnemonicBytes.isEmpty) {
      throw StateError('Mnemonic not found for payment link account.');
    }
    late final Future<rust_sync.ExecuteProposalResult> result;
    try {
      result = rust_sync.executeProposal(
        dbPath: dbPath,
        lightwalletdUrl: lightwalletdUrl,
        proposalId: proposalId,
        sendFlowId: sendFlowId,
        mnemonicBytes: mnemonicBytes,
        spendParamsPath: needsSaplingParams ? saplingParams.spendPath : null,
        outputParamsPath: needsSaplingParams ? saplingParams.outputPath : null,
      );
    } finally {
      _zeroize(mnemonicBytes);
    }
    return result;
  }

  Future<void> _runBlockingSync({required String dbPath}) async {
    final endpoint = _ref.read(rpcEndpointProvider);
    await rust_sync.runFullSyncBlocking(
      dbPath: dbPath,
      lightwalletdUrl: endpoint.normalizedLightwalletdUrl,
      network: endpoint.networkName,
      mode: 1,
    );
  }

  Future<({Directory directory, String dbPath})>
  _createTemporaryWalletDb() async {
    final supportDir = await getWalletSupportDirectory();
    final random = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final separator = Platform.pathSeparator;
    final directory = Directory(
      '${supportDir.path}${separator}payment_link_claim_$suffix',
    );
    await directory.create(recursive: true);
    return (
      directory: directory,
      dbPath: '${directory.path}${separator}zcash_wallet.db',
    );
  }

  Future<void> _deleteTemporaryWalletDb(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (e, st) {
      log(
        'PaymentLinkService: failed to delete temporary payment-link DB '
        '${directory.path}: $e\n$st',
      );
    }
  }

  Future<void> _requireShieldedAddress(String address) async {
    final validation = await rust_sync.validateAddress(address: address);
    if (!validation.isValid ||
        (validation.addressType != 'unified' &&
            validation.addressType != 'sapling')) {
      throw StateError('Payment links only support shielded addresses.');
    }
  }

  String _newSendFlowId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _zeroize(Uint8List bytes) {
    bytes.fillRange(0, bytes.length, 0);
  }
}
