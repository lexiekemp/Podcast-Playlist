//
//  QueueHomeContoller.swift
//  Snipgram
//
//  Created by Snip Inc. on 5/19/18.
//  Copyright © 2018 Snip Inc. All rights reserved.
//

import UIKit
import AVFoundation
import CoreData
import Mixpanel
import Firebase

struct CellUserStats {
    var listenCount: Int
    var likeCount: Int
    var commentCount: Int
    var isInQueue:Bool
    var isLiked: Bool
    var percentListened: Int
    var isListened: Bool
    var isDownloaded: Bool
}
enum PlayerState {
    case loading, playing, paused
}
extension Notification.Name {
    static let queueItemAdded = Notification.Name("queueItemAdded")
    static let queueItemRemoved = Notification.Name("queueItemRemoved")
}
//view controller for playlist, episodes in playlist are stored in Core Data
class QueueHomeController : ModalPresenterViewController, UITableViewDelegate, UITableViewDataSource, StatsRefresher, DownloadDelegate  {
    
    var managedObjectContext: NSManagedObjectContext? { didSet { updateTable() }}
    var player: AVQueuePlayer?
    var playerItem: AVPlayerItem?
    private var playrate: Float = 0.0
    private let refreshControl = UIRefreshControl()
    var episodes: [Episode] = []
    var cellUserStats: [CellUserStats] = [] //keep track of how the user has interacted with each episode for display
    var cellPlayerStates: [Int:PlayerState] = [:] //keep track of which episode is playing or loading
    var cellPlayerItems: [AVPlayerItem?] = []
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var swipeLabelHeightConstraint: NSLayoutConstraint!
    
    var playerIsLoading = false
    var playingRow: Int? = nil
    var downloadingDict: [Int:Float] = [:] //row:progress
    var needReload = false
    var statsTasks = 0
    
    //set up dowloading an episode
    let downloadService = DownloadService()
    lazy var downloadsSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    //fetch episode in playlist from core data
    var fetchedResultsController: NSFetchedResultsController<NSFetchRequestResult>? {
        didSet {
            do {
                if let frc = fetchedResultsController {
                    frc.delegate = self
                    try frc.performFetch()
                }
                needReload = true
                refreshStats()
            } catch let error {
                print("NSFetchedResultsController.performFetch() failed: \(error)")
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let clearButton = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearTableClicked))
        self.navigationItem.leftBarButtonItem = clearButton
        self.navigationItem.rightBarButtonItem = self.editButtonItem

        downloadService.downloadsSession = downloadsSession
        
        tableView.delegate = self
        tableView.dataSource = self
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refreshTable(_:)), for: .valueChanged)
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        self.managedObjectContext = appDelegate.persistentContainer.viewContext
        player = appDelegate.player
        
        //set table view header
        tableView.register(UINib(nibName: "QueueHeaderView", bundle: Bundle.main), forHeaderFooterViewReuseIdentifier: "QueueHeader")
        tableView.register(UINib(nibName: "QueueFooterView", bundle: Bundle.main), forHeaderFooterViewReuseIdentifier: "QueueFooter")
        
        //if user adds or removes an episode to the playlist on another view, update the playlist so when they return to the playlist, they will see the added item
        NotificationCenter.default.addObserver(self, selector: #selector(QueueHomeController.handleChangedQueueItem), name: NSNotification.Name.queueItemAdded, object: nil)
         NotificationCenter.default.addObserver(self, selector: #selector(QueueHomeController.handleChangedQueueItem), name: NSNotification.Name.queueItemRemoved, object: nil)
    }
    //give the user information about the playlist the first time they visit the page
    func onboardingPopup() {
        if let user = Auth.auth().currentUser {
            let key = "\(user.uid)_\(OnboardingKeys.playlist)"
            if UserDefaults.standard.value(forKey: key) != nil {
                let alert = UIAlertController(title: "Episodes are automatically added to the playlist if you subscribe to a show.", message: nil, preferredStyle: .alert)
                let okay = UIAlertAction(title: "Okay", style: .default) { _ in
                    UserDefaults.standard.removeObject(forKey: key)
                }
                alert.addAction(okay)
                self.present(alert, animated: true, completion: nil)
            }
        }
    }
    //if a user interacts with an episode in the playlist, eg liked an episode from the player screen
    @objc func handleChangedQueueItem(notification: NSNotification) {
        updateTable()
    }
    func refreshStats() {
        //downloads
        if let cells = self.tableView.visibleCells as? [QueueTableViewCell] {
            for cell in cells {
                if let row = cell.row {
                    if let progress = downloadingDict[row] {
                        cell.downloadProgress = progress
                        cell.downloadButtonState = .downloading
                    }
                }
            }
        }
        
        //episode stats
        self.episodes = []
        self.cellPlayerItems = []
        var tasks = 0
        guard let queueItems = fetchedResultsController?.fetchedObjects as? [QueueItem] else { return }
        let defaultStats = CellUserStats(listenCount: 0, likeCount: 0, commentCount: 0, isInQueue: true, isLiked: false, percentListened: 0, isListened: false, isDownloaded: false)
        self.cellUserStats = Array(repeating: defaultStats, count: queueItems.count)
        self.cellPlayerItems = Array(repeating: nil, count: queueItems.count)
        for i in 0..<queueItems.count {
            let queueItem = queueItems[i]
            if queueItem.audioUrl != nil {
                if let downloadedUrl = QueueDownloadManager.retrieveEpisode(audioUrl: queueItem.audioUrl!.absoluteString) {
                    cellPlayerItems[i] = AVPlayerItem(url: downloadedUrl)
                }
                else {
                    cellPlayerItems[i] = AVPlayerItem(url: queueItem.audioUrl!)
                }
            }
            tasks += 1
            if queueItem.episodeId != nil {
                FirebaseDataManager.getEpisode(episodeId: queueItem.episodeId!) { [weak self] episode in
                    if episode != nil, queueItem.episodeId != nil {
                        self?.episodes.append(episode!)
                        self?.updateUserStats(episode: episode!, epId: queueItem.episodeId!, row: i)
                    }
                    tasks -= 1
                }
            }
        }
    }
    //populate user stats for an episode
    func updateUserStats(episode: Episode, epId: String, row: Int) {
        let listenCount = episode.listenCount
        let likeCount = episode.likeCount
        let commentCount = episode.commentCount
        
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let context = appDelegate.persistentContainer.viewContext
        var percentListened = 0
        var isListened = false
        if let listenedObj = ListenedTo.getListenedToObject(audioUrl: episode.audioUrl.absoluteString, inManagedObjectContext: context) {
            if listenedObj.isListened {
                isListened = true
            }
            let duration = episode.duration
            let ratio = listenedObj.time/Float(duration)
            percentListened = Int(ratio * 100)
        }
        var downloaded = false
        if QueueDownloadManager.retrieveEpisode(audioUrl: episode.audioUrl.absoluteString) != nil {
            downloaded = true
        }
        FirebaseDataManager.hasLikedEpisode(episodeId: epId) { [weak self] isLiked in
            guard let strongSelf = self else { return }
            let newStats = CellUserStats(listenCount: listenCount, likeCount: likeCount, commentCount: commentCount, isInQueue: true, isLiked: isLiked, percentListened: percentListened, isListened: isListened, isDownloaded: downloaded)
            if row < strongSelf.cellUserStats.count {
                strongSelf.cellUserStats[row] = newStats
                strongSelf.statsTasks -= 1
                if strongSelf.needReload {
                    if strongSelf.statsTasks == 0 {
                        strongSelf.needReload = false
                        strongSelf.tableView.reloadData()
                    }
                }
                else {
                    if let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? QueueTableViewCell {
                        cell.updateStats(stats: newStats)
                    }
                }
            }
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        self.navigationController?.navigationBar.shadowImage = UIImage()
        self.navigationController?.navigationBar.backgroundColor = UIColor.white
        self.navigationController?.navigationBar.barTintColor = UIColor.white
        Mixpanel.mainInstance().time(event: "Playlist Duration")
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onboardingPopup()
        if let queueItems = fetchedResultsController?.fetchedObjects as? [QueueItem], queueItems.isEmpty {
            updateTable()
        }
        else {
            refreshStats()
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        self.navigationController?.navigationBar.shadowImage = nil
        self.navigationController?.navigationBar.backgroundColor = nil
        self.navigationController?.navigationBar.barTintColor = nil
        self.navigationController?.navigationBar.shadowImage = nil
        Mixpanel.mainInstance().track(event: "Playlist Duration")
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    @objc func unavailableAlert(_ sender: UIButton) {
        let alert = UIAlertController(title: "The feature is currently in development.", message: nil, preferredStyle: .alert)
        let okay = UIAlertAction(title: "Okay", style: .default, handler: nil)
        alert.addAction(okay)
        self.present(alert, animated: true)
    }
    //add oberserver for when the episode is finished
    func addPlayerObserver() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(episodeDidFinish(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }
    //update UI when loading in episode
    func startedLoadingCell(row: Int) {
        self.playerIsLoading = true
        self.playingRow = row
        guard let cells = self.tableView.visibleCells as? [QueueTableViewCell] else { return } //update UI of visibile cells
        for cell in cells {
            cell.updatePlayPauseButton()
        }
    }
    //check if the current episode playing is in the playlist
    private func isQueuePlaying() -> Bool {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        if let currentItem = appDelegate.player.currentItem?.asset as? AVURLAsset {
            let currentUrl = currentItem.url.lastPathComponent
            if let queueItems = fetchedResultsController?.fetchedObjects as? [QueueItem] {
                if queueItems.index(where: {$0.audioUrl?.lastPathComponent == currentUrl}) != nil {
                    return true
                }
            }
        }
        return false
    }
    @objc func clearTableClicked() {
        let clearAlert = UIAlertController(title: "Do you want to clear the whole playlist?", message: nil, preferredStyle: .alert)
        
        let confirmAction = UIAlertAction(title: "Confirm", style: .destructive) { [weak self] action in
            self?.clearTable()
        }
        clearAlert.addAction(confirmAction)
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .default) {
            action in
            return //just dismiss alert
        }
        clearAlert.addAction(cancelAction)
        self.present(clearAlert, animated: true)
    }
    //remove all items in playlist from Core Data
    func clearTable() {
        self.refreshControl.beginRefreshing()
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let context = appDelegate.persistentContainer.viewContext
        QueueItem.removeAllQueueItems(inManagedObjectContext: context) { [weak self] _ in
            self?.refreshControl.endRefreshing()
            self?.episodes = []
            self?.cellPlayerStates = [:]
            self?.cellUserStats = []
            self?.cellPlayerItems = []
        }
    }
    //start playing the next episode in the playlist when the current episode finishes
    @objc func episodeDidFinish(_ notification: NSNotification) {
        if !isQueuePlaying() { return }
        player?.advanceToNextItem()
        if let currentItem = player?.currentItem?.asset as? AVURLAsset {
            let currentUrl = currentItem.url.lastPathComponent
            if let queueItems = fetchedResultsController?.fetchedObjects as? [QueueItem] {
                if let index = queueItems.index(where: {$0.audioUrl?.lastPathComponent == currentUrl}) {
                    let indexPath = IndexPath(row: index, section: 0)
                    if let cell = tableView.cellForRow(at: indexPath) as? QueueTableViewCell {
                        cell.setupCurrentEpisodeForPlay()
                    }
                }
            }
        }
    }
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }
    //fetch items in playlist from Core Data
    func updateTable() {
        if let context = managedObjectContext {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName:"QueueItem")
            request.sortDescriptors = [NSSortDescriptor(key: "index", ascending: false)]
            fetchedResultsController = NSFetchedResultsController(fetchRequest: request, managedObjectContext: context, sectionNameKeyPath: nil, cacheName: nil)
        }
        else {
            fetchedResultsController = nil
        }
    }
    func getPlayerForCell(row: Int) -> AVPlayerItem? {
        for i in 0..<cellPlayerItems.count {
            print("url at \(i) is \((cellPlayerItems[i]!.asset as! AVURLAsset).url.lastPathComponent)")
        }
        if row < cellPlayerItems.count {
            return cellPlayerItems[row]
        }
        return nil
    }
    //BUTTON FUNCTIONS FOR SHOW DETAILS TABLE VIEW CELL
    //update cell user stats to keep UI consistent
    func downloaded(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isDownloaded = true
        }
    }
    func undownloaded(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isDownloaded = false
        }
    }
    func liked(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isLiked = true
            cellUserStats[row].likeCount += 1
        }
    }
    func unLiked(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isLiked = false
            cellUserStats[row].likeCount = max(0, cellUserStats[row].likeCount-1)
        }
    }
    func setListened(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isListened = true
        }
    }
    func setUnlistened(row: Int) {
        if row < cellUserStats.count {
            cellUserStats[row].isListened = false
        }
    }
    func setPlayerState(_ state: PlayerState, row: Int) {
        cellPlayerStates[row] = state
    }
    func getPlayerState(row: Int) -> PlayerState {
        if let state = cellPlayerStates[row] {
            return state
        }
        return PlayerState.paused
    }
    
    func setPlayerItem(row: Int, item: AVPlayerItem) {
        if row < cellPlayerItems.count {
            cellPlayerItems[row] = item
        }
    }
    // MARK: UITableViewDataSource
    func numberOfSections(in tableView: UITableView) -> Int {
        return fetchedResultsController?.sections?.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if let sections = fetchedResultsController?.sections, sections.count > 0 {
            return sections[section].numberOfObjects
        }
        return 0
    }
    //remove the header title when user scrolls down
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset.y > (self.navigationController?.navigationBar.frame.size.height ?? 50) {
            self.navigationItem.title = "Playlist"
            self.navigationController?.navigationBar.shadowImage = nil
        }
        else {
            self.navigationItem.title = ""
            self.navigationController?.navigationBar.shadowImage = UIImage()
        }
    }
    // MARK: UITableViewDelegate
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "queueCell", for: indexPath) as! QueueTableViewCell
        cell.setShadow()
        if let queueItem = fetchedResultsController?.object(at: indexPath) as? QueueItem {
            cell.inflate(item: queueItem, indexPath: indexPath, parent: self)
            if indexPath.row < cellUserStats.count {
                cell.updateStats(stats: cellUserStats[indexPath.row])
            }
            if let progress = downloadingDict[indexPath.row] {
                cell.downloadProgress = progress
                cell.downloadButtonState = .downloading
            }
        }
        cell.selectionStyle = .none
        cell.showsReorderControl = true
        return cell
    }
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 50
    }
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let cellTableViewHeader = tableView.dequeueReusableHeaderFooterView(withIdentifier: "QueueHeader")
        return cellTableViewHeader
    }
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 60
    }
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let cellTableViewFooter = tableView.dequeueReusableHeaderFooterView(withIdentifier: "QueueFooter")
        return cellTableViewFooter
    }
    // Support editing (for deletion of playlist items)
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            let context = appDelegate.persistentContainer.viewContext
            if let queueItemToDelete = fetchedResultsController?.object(at: indexPath) as? QueueItem {
                QueueItem.removeQueueItem(episode: Episode(queueItem: queueItemToDelete), inManagedObjectContext: context) //remove playlist item from Core Data
                //remove information about playlist item
                if indexPath.row < cellPlayerItems.count {
                    cellPlayerItems.remove(at: indexPath.row)
                }
                if indexPath.row < cellUserStats.count {
                    cellUserStats.remove(at: indexPath.row)
                }
            }
        }
    }
    // Support reordering of the playlist items
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to toIndexPath: IndexPath) {
        self.fetchedResultsController?.delegate = nil
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let context = appDelegate.persistentContainer.viewContext
        guard let queueItemToMove = fetchedResultsController?.object(at: fromIndexPath) as? QueueItem else { print("error getting queue Item to move"); return }
        guard let queueItemAtDestination = fetchedResultsController?.object(at: toIndexPath) as? QueueItem else { print("error getting queue Item to move"); return }
        
        let fromRow = queueItemToMove.index
        let toRow = queueItemAtDestination.index
        //switch index of playlist items in Core Data
        QueueItem.moveQueueItem(fromIndex: Int(fromRow), toIndex: Int(toRow), inManagedObjectContext: context) { [weak self] _ in
            self?.fetchedResultsController?.delegate = self
        }
        //switch index of information about playlist items
        if fromIndexPath.row < cellPlayerItems.count, toIndexPath.row < cellPlayerItems.count {
            let playerItemToMove = cellPlayerItems[fromIndexPath.row]
            cellPlayerItems.remove(at: fromIndexPath.row)
            cellPlayerItems.insert(playerItemToMove, at: toIndexPath.row)
        }
        if fromIndexPath.row < cellUserStats.count, toIndexPath.row < cellUserStats.count {
            let statsToMove = cellUserStats[fromIndexPath.row]
            cellUserStats.remove(at: fromIndexPath.row)
            cellUserStats.insert(statsToMove, at: toIndexPath.row)
        }
    }
    // Selection, show details about episode when user clicks on and item
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let queueItem = fetchedResultsController?.object(at: indexPath) as? QueueItem {
            if queueItem.episodeId != nil {
                self.presentEpisodeDetailScreen(episodeId: queueItem.episodeId!, statsRefresher: self)
            }
        }
    }
    func goToEpisodeDetails(row: Int) {
        if let queueItem = fetchedResultsController?.object(at: IndexPath(row: row, section: 0)) as? QueueItem {
            if queueItem.episodeId != nil {
                self.presentEpisodeDetailScreen(episodeId: queueItem.episodeId!, statsRefresher: self)
            }
        }
    }
    func getQueueItems() -> [QueueItem]? {
        if let queueItems = fetchedResultsController?.fetchedObjects as? [QueueItem] {
            return queueItems
        }
        return nil
    }

    //Background refresh
    func backgroundQueueUpdate(completion: @escaping (UIBackgroundFetchResult) -> ()) {
        fetchNewEpisodesOp(sendNotifications: true) { dataFound in
            if dataFound {
                completion(.newData)
            }
            else {
                completion(.noData)
            }
        }
    }
    //used to refresh playlist (manually or in the background), read the rss feed of the podcasts the user has subscribed to to add the newest episodes
    func fetchNewEpisodesOp(sendNotifications: Bool = false, completion: @escaping (Bool) -> ()) {
        var dataFound = false
        var finished = false
        //get the podcasts the user has subscribed to from Firebase
        FirebaseDataManager.getUserSubscriptions() { subscriptions in
            var processes = subscriptions.count
            var tasks = 0
            DispatchQueue.global(qos: .background).async { //perform the update in the background so that the main thread is not blocked
                for bookmarkedShow in subscriptions {
                    if bookmarkedShow.lastUpdatedTime == nil { //this should not happen
                        DispatchQueue.main.async {
                            FirebaseDataManager.updateLastUpdated(showId: bookmarkedShow.showAppleCollectionId)
                        }
                        continue
                    }
                    //get the episodes that came out since the last update time
                    FeedDownload.readNewFeed(lastUpdatedTime: bookmarkedShow.lastUpdatedTime!, showId: bookmarkedShow.showAppleCollectionId, title: bookmarkedShow.showTitle, showSmallImage: bookmarkedShow.showSmallArtUrl, showLargeArtUrl: bookmarkedShow.showLargeArtUrl, feedUrl: bookmarkedShow.feedUrl) { newEpisodes, totalEpCount in
                        DispatchQueue.main.async {
                            tasks += newEpisodes.count
                            if newEpisodes.count > 0 {
                                dataFound = true
                            }
                            //update the number of episodes in that show in Firebase
                            FirebaseDataManager.updateEpisodeCount(showId: bookmarkedShow.showAppleCollectionId, newCount: totalEpCount)
                            let appDelegate = UIApplication.shared.delegate as! AppDelegate
                            let context = appDelegate.persistentContainer.viewContext
                            //add the new episodes to the playlist through Core Data
                            for episode in newEpisodes {
                                QueueItem.addQueueItem(episode: episode, inManagedObjectContext: context) { _ in
                                    tasks -= 1
                                    if processes == 0, tasks == 0, !finished {
                                        finished = true
                                        completion(dataFound)
                                        print("finished adding queue items.")
                                    }
                                }
                            }
                            //send a notification to the users phone about the new episodes
                            if newEpisodes.count > 0, sendNotifications {
                                NotificationManager.newEpisodesNotification(showTitle: bookmarkedShow.showTitle, newestEpisodeTitle: newEpisodes[0].episodeTitle, newEpisodeCount: newEpisodes.count)
                            }
                            //update the time in Firebase when the show was las updated
                            FirebaseDataManager.updateLastUpdated(showId: bookmarkedShow.showAppleCollectionId)
                            processes -= 1
                            if processes == 0, tasks == 0, !finished {
                                finished = true
                                completion(dataFound)
                                print("finished fetching new episodes - no new.")
                            }
                        }
                    }
                }
            }
        }
    }
    func getTimeStamp(_ stringToConvert: String) -> Int64? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyy HH:mm:ss z"
        if let date = dateFormatter.date(from: stringToConvert) {
            let milliseconds = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            return milliseconds
        }
        return nil
    }
    @objc private func refreshTable(_ sender: Any) {
       fetchNewEpisodesOp() { dataFound in
            DispatchQueue.main.async { [weak self] in
                self?.refreshControl.endRefreshing()
                self?.updateTable()
            }
        }
    }
}
//control downloading progress of episodes
extension QueueHomeController: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Float(totalBytesWritten)/Float(totalBytesExpectedToWrite)
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let download = downloadService.activeDownloads[sourceURL]
        downloadProgressUpdated(to: progress, forCell: download?.cellRow)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        print("Finished downloading to \(location).")
        guard let sourceURL = downloadTask.originalRequest?.url else { return }
        let download = downloadService.activeDownloads[sourceURL]
        downloadService.activeDownloads[sourceURL] = nil

        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            self.downloadComplete(fileUrl: nil, row: download?.cellRow)
            return
        }
        let folderPath = documentsDirectory.appendingPathComponent("Podcast_Downloads", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(atPath: folderPath.path, withIntermediateDirectories: true)
        }
        catch let error as NSError {
            print(error.localizedDescription)
            self.downloadComplete(fileUrl: nil, row: download?.cellRow)
            return
        }
        
        let fileUrl = folderPath.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            // after downloading episode move it to fileUrl
            try FileManager.default.moveItem(atPath: location.path, toPath: fileUrl.path)
            self.downloadComplete(fileUrl: fileUrl, row: download?.cellRow)
        } catch let error as NSError {
            print(error.localizedDescription)
            self.downloadComplete(fileUrl: nil, row: download?.cellRow)
            return
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error != nil) {
            guard let sourceURL = task.originalRequest?.url else { return }
            let download = downloadService.activeDownloads[sourceURL]
            print("didCompleteWithError \(error!.localizedDescription)")
            self.downloadComplete(fileUrl: nil, row: download?.cellRow)
        }
        else {
            print("The task finished successfully")
        }
    }
    func startDownload(audioUrl: URL, row: Int) {
        downloadingDict[row] = 0
        downloadService.startDownload(audioUrl: audioUrl, cellRow: row)
    }
    func downloadCanceled(row: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.downloadingDict[row] = nil
            if let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row, section: 0)) as? QueueTableViewCell {
                cell.downloadButtonState = .undownloaded
                cell.isDownloaded = false
                print("downloading queueItem canceled")
            }
        }
    }
    //update tableview cell UI for finished downloading
    func downloadComplete(fileUrl: URL?, row: Int?) {
        if row == nil {
            print("downloading row nil")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.downloadingDict[row!] = nil
            if let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row!, section: 0)) as? QueueTableViewCell {
                if fileUrl == nil {
                    cell.downloadButtonState = .undownloaded
                    cell.isDownloaded = false
                    print("Error downloading queueItem")
                    let title = cell.episodeTitleLabel.text ?? ""
                    let alert = UIAlertController(title: "Error downloading \(title)", message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Okay", style: .default, handler: nil))
                    strongSelf.present(alert, animated: true)
                }
                else {
                    print("QueueItem successfully Downloaded")
                    cell.isDownloaded = true
                    cell.audioFileUrl = fileUrl
                    strongSelf.downloaded(row: row!)
                    let item = AVPlayerItem(url: fileUrl!)
                    strongSelf.setPlayerItem(row: row!, item: item)
                }
            }
        }
    }
    //update the spinner in the table view cells
    func downloadProgressUpdated(to progress: Float, forCell row: Int?) {
        if row == nil { return }
        downloadingDict[row!] = progress
        DispatchQueue.main.async { [weak self] in
            guard let strongSelf = self else { return }
            if let cell = strongSelf.tableView.cellForRow(at: IndexPath(row: row!, section: 0)) as? QueueTableViewCell {
                cell.downloadProgress = progress
            }
        }
    }
    func cancelDownload(audioUrl: URL) {
        if let download = downloadService.activeDownloads[audioUrl] {
            download.task?.cancel()
            downloadService.activeDownloads[audioUrl] = nil
            self.downloadCanceled(row: download.cellRow)
        }
    }
}
//makes smooth animations in table view when core data is updated
extension QueueHomeController: NSFetchedResultsControllerDelegate {
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.beginUpdates()
    }
    
    func controller(controller: NSFetchedResultsController<NSFetchRequestResult>, didChangeSection sectionInfo: NSFetchedResultsSectionInfo, atIndex sectionIndex: Int, forChangeType type: NSFetchedResultsChangeType) {
        switch type {
        case .insert: tableView.insertSections(IndexSet(integer: sectionIndex), with: .fade)
        case .delete: tableView.deleteSections(IndexSet(integer: sectionIndex), with: .fade)
        default: break
        }
    }
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        switch type {
        case .insert:
            tableView.insertRows(at: [newIndexPath!], with: .fade)
        case .delete:
            tableView.deleteRows(at: [indexPath!], with: .fade)
        case .update:
            tableView.reloadRows(at: [indexPath!], with: .fade)
        case .move:
            tableView.deleteRows(at: [indexPath!], with: .fade)
            tableView.insertRows(at: [newIndexPath!], with: .fade)
        }
    }
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.endUpdates()
    }
}
extension String {
    var url: URL? {
        if let NSUrl = NSURL(string: self) {
            let url = NSUrl as URL
            return url
        }
        return nil
    }
}


extension UITableViewCell {
    func setShadow() {
        self.backgroundColor = .clear
        self.layer.masksToBounds = false
        self.layer.shadowOpacity = 0.5
        self.layer.shadowRadius = 3
        self.layer.shadowOffset = CGSize(width: 0, height: 0)
        self.layer.shadowColor = UIColor.black.cgColor
        self.contentView.backgroundColor = .white
    }
}
