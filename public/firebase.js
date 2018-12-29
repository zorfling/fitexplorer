// Initialize Firebase
var config = {
  apiKey: 'AIzaSyBDGAVFJ8HaeUHDPyYCUN_vzfeyn1oasKE',
  authDomain: 'gfitexplorer-965e7.firebaseapp.com',
  databaseURL: 'https://gfitexplorer-965e7.firebaseio.com',
  projectId: 'gfitexplorer-965e7',
  storageBucket: 'gfitexplorer-965e7.appspot.com',
  messagingSenderId: '40197833455'
};
firebase.initializeApp(config);

// Initialize Cloud Firestore through Firebase
var db = firebase.firestore();

// Disable deprecated features
db.settings({
  timestampsInSnapshots: true
});
