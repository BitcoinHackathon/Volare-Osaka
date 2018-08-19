//
//  ViewController.swift
//  SampleWallet
//
//  Created by Akifumi Fujita on 2018/08/17.
//  Copyright © 2018年 Akifumi Fujita. All rights reserved.
//

import UIKit
import BitcoinKit

class HomeViewController: UITableViewController {
    
    var wallet: Wallet?
    var transactions = [CodableTx]()
    
    @IBOutlet weak var qrCodeImageView: UIImageView!
    @IBOutlet weak var addressLabel: UILabel!
    @IBOutlet weak var balanceLabel: UILabel!
    @IBOutlet weak var sendButton: UIButton!
    
    @IBAction func sendButtonTapped(_ sender: Any) {
        let sendViewController = storyboard?.instantiateViewController(withIdentifier: "SendViewController") as! SendViewController
        navigationController?.pushViewController(sendViewController, animated: true)
        
        makeTransaction1(amount: 10000)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let _ = AppController.shared.wallet else {
            createWallet()
            return
        }
        
        //print("Mock result:", MockPlayGround().verifyScript())
    }
    
    override func viewWillAppear(_ animated: Bool) {
        updateUI()
    }

    
    private func updateUI() {
        getAddress()
        getBalance()
        getTxHistory()
    }
    
    public func makeTransaction1(amount: Int64) {
        // 1. ユーザーのpubkeyを取得
        let pubUser = AppController.shared.wallet!.publicKey
        let base58Address = pubUser.toLegacy()
        // 1.1 ユーザーのcashAddressを取得
        let cashaddrUser = pubUser.toCashaddr()
        
        // 2. ユーザーのutxoの取得
        let legacyAddress: String = AppController.shared.wallet!.publicKey.toLegacy().description
        APIClient().getUnspentOutputs(withAddresses: [legacyAddress], completionHandler: { [weak self] (unspentOutputs: [UnspentOutput]) in
            guard let strongSelf = self else {
                return
            }
            let utxos = unspentOutputs.map { $0.asUnspentTransaction() }
            // 3. 送金に必要なUTXOの選択
            let (utxoss, fee) = (self?.selectTx(utxos: utxos, amount: amount))!
            let totalAmount: Int64 = utxoss.reduce(0) { $0 + $1.output.value }
            let change: Int64 = totalAmount - amount - fee
            
            // 4. unlockスクリプトを決める
            // 4.1 先ずはmultiSignagtureのlock
            let pubCar = MockKey.keyB.pubkey
            let cashaddrCar = pubCar.toCashaddr()
            let multiSigLockScript = ScriptFactory.Standard.buildMultiSig(publicKeys: [pubUser, pubCar], signaturesRequired: 2)!
            let lockTimeA = ScriptFactory.LockTime.build(address: pubUser.toCashaddr(), lockIntervalSinceNow: 60*60*24)!
            let fullScriptTo = ScriptFactory.Condition.build(scripts: [multiSigLockScript, lockTimeA])!//.toP2SH()
            let lockScriptChange = Script(address: cashaddrUser)!
            
            // 5. outputの準備
            let toOutput = TransactionOutput(value: amount, lockingScript: fullScriptTo.data)
            let changeOutput = TransactionOutput(value: change, lockingScript: lockScriptChange.data)
            
            // 6. UTXOとTransactionOutputを合わせて、UnsignedTransactionを作る
            let unsignedInputs = utxos.map { TransactionInput(previousOutput: $0.outpoint, signatureScript: Data(), sequence: UInt32.max) }
            let tx = Transaction(version: 1, inputs: unsignedInputs, outputs: [toOutput, changeOutput], lockTime: 0)
            let unsignedTx = UnsignedTransaction(tx: tx, utxos: utxoss)
            let signedTx = strongSelf.signTx(unsignedTx: unsignedTx, keys: [AppController.shared.wallet!.privateKey])
            let rawTx = signedTx.serialized().hex
            // 7. 署名されたtxをbroadcastする
            
            APIClient().postTx(withRawTx: rawTx, completionHandler: { (txid, error) in
                if let txid = txid {
                    print("txid = \(txid)")
                    print("txhash: https://test-bch-insight.bitpay.com/tx/\(txid)")
                } else {
                    print("error post \(error ?? "error = nil")")
                }
            })
        })
    }
    
    // 署名
    public func signTx(unsignedTx: UnsignedTransaction, keys: [PrivateKey]) -> Transaction {
        var inputsToSign = unsignedTx.tx.inputs
        var transactionToSign: Transaction {
            return Transaction(version: unsignedTx.tx.version, inputs: inputsToSign, outputs: unsignedTx.tx.outputs, lockTime: unsignedTx.tx.lockTime)
        }
        
        // Signing
        let hashType = SighashType.BCH.ALL
        for (i, utxo) in unsignedTx.utxos.enumerated() {
            let pubkeyHash: Data = Script.getPublicKeyHash(from: utxo.output.lockingScript)
            
            let keysOfUtxo: [PrivateKey] = keys.filter { $0.publicKey().pubkeyHash == pubkeyHash }
            guard let key = keysOfUtxo.first else {
                continue
            }
            
            let sighash: Data = transactionToSign.signatureHash(for: utxo.output, inputIndex: i, hashType: SighashType.BCH.ALL)
            let signature: Data = try! Crypto.sign(sighash, privateKey: key)
            let txin = inputsToSign[i]
            let pubkey = key.publicKey()
            
            // unlockScriptを作る
            let unlockingScript = Script.buildPublicKeyUnlockingScript(signature: signature, pubkey: pubkey, hashType: hashType)
            let _ = try! Script().appendData(signature + UInt8(hashType)).appendData(pubkey.raw)
            let _ = try! Script() // [OP_0 sigA sigB] [lockScript.data]
            // TODO: sequenceの更新
            inputsToSign[i] = TransactionInput(previousOutput: txin.previousOutput, signatureScript: unlockingScript, sequence: txin.sequence)
        }
        return transactionToSign
    }
    
    // 手数料の設定
    public func selectTx(utxos: [UnspentTransaction], amount: Int64) -> (utxos: [UnspentTransaction], fee: Int64) {
        return (utxos, 500)
    }
    
    // walletの作成
    private func createWallet() {
        let privateKey = PrivateKey(network: .testnet)
        let wif = privateKey.toWIF()
        AppController.shared.importWallet(wif: wif)
    }
    
    // Addressの表示
    private func getAddress() {
        let pubkey = AppController.shared.wallet!.publicKey
        let base58Address = pubkey.toLegacy()
        print("base58Address: \(base58Address)")
        let cashAddr = pubkey.toCashaddr().cashaddr
        print("cashAddr: \(cashAddr)")
        addressLabel.text = cashAddr
        qrCodeImageView.image = generateVisualCode(address: cashAddr)
    }
    
    // 残高を確認する
    private func getBalance() {
        APIClient().getUnspentOutputs(withAddresses: [AppController.shared.wallet!.publicKey.toLegacy().description], completionHandler: { [weak self] (utxos: [UnspentOutput]) in
            let balance = utxos.reduce(0) { $0 + $1.amount }
            DispatchQueue.main.async { self?.balanceLabel.text = "\(balance) tBCH" }
        })
    }
    
    // 過去のトランザクションの履歴の取得
    private func getTxHistory() {
        APIClient().getTransaction(withAddresses: AppController.shared.wallet!.publicKey.toLegacy().description, completionHandler: { [weak self] (transactrions:[CodableTx]) in
            self?.transactions = transactrions
            DispatchQueue.main.async { self?.tableView.reloadData() }
        })
    }
    
    private func updateBalance2() {
        let cashaddr = AppController.shared.wallet!.publicKey.toCashaddr().cashaddr
        let address = cashaddr.components(separatedBy: ":")[1]
        let addition = transactions.filter { $0.direction(addresses: [address]) == .received }.reduce(0) { $0 + $1.amount(addresses: [address]) }
        let subtraction = transactions.filter { $0.direction(addresses: [address]) == .sent }.reduce(0) { $0 + $1.amount(addresses: [address]) }
        let balance = addition - subtraction
        balanceLabel.text = "\(balance) tBCH"
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return "Transactions"
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return transactions.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TransactionCell", for: indexPath)
        
        let transaction = transactions[indexPath.row]
        
        let cashaddr = AppController.shared.wallet!.publicKey.toCashaddr().cashaddr
        let address = cashaddr.components(separatedBy: ":")[1]
        
        let value = transaction.amount(addresses: [address])
        let direction = transaction.direction(addresses: [address])
        let messages = transaction.messages().joined(separator: ",")
        
        switch direction {
        case .sent:
            cell.textLabel?.text = "- \(value): \(messages)"
        case .received:
            cell.textLabel?.text = "+ \(value): \(messages)"
        }
        
        cell.textLabel?.textColor = direction == .sent ? #colorLiteral(red: 0.7529411765, green: 0.09803921569, blue: 0.09803921569, alpha: 1) : #colorLiteral(red: 0.3882352941, green: 0.7843137255, blue: 0.07843137255, alpha: 1)
        
        return cell
    }
    
    private func generateVisualCode(address: String) -> UIImage? {
        let parameters: [String : Any] = [
            "inputMessage": address.data(using: .utf8)!,
            "inputCorrectionLevel": "L"
        ]
        let filter = CIFilter(name: "CIQRCodeGenerator", withInputParameters: parameters)
        
        guard let outputImage = filter?.outputImage else {
            return nil
        }
        
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let cgImage = CIContext().createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
}
