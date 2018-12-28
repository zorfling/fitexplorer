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

var annotations = [];

db.collection('annotations')
  .orderBy('date')
  .get()
  .then(function(querySnapshot) {
    querySnapshot.forEach(function(doc) {
      var data = doc.data();
      var theDate = new Date((data.date.seconds + 10 * 60 * 60) * 1000);
      annotations.push({
        date: theDate,
        annotation: data.annotation,
        annotationText: data.annotationText
      });
    });
  })
  .catch(function(error) {
    console.log('Error getting documents: ', error);
  });

console.log(annotations);
