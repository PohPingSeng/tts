import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:math';
import 'widgets/custom_bottom_nav.dart';
import 'models/trip_location.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'services/trip_state_manager.dart';
import 'services/map_cache_service.dart';
import 'transportation_route.dart';
import 'services/trip_plan_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/session_manager.dart';
import 'multi_transportation_route.dart';

class TripPlanPage extends StatefulWidget {
  final String userEmail;
  final Map<String, dynamic>? initialPlace;
  final List<TripLocation>? savedLocations;
  final String? tripId;

  const TripPlanPage({
    Key? key,
    required this.userEmail,
    this.initialPlace,
    this.savedLocations,
    this.tripId,
  }) : super(key: key);

  @override
  State<TripPlanPage> createState() => _TripPlanPageState();
}

class _TripPlanPageState extends State<TripPlanPage> {
  final TextEditingController _searchController = TextEditingController();
  GoogleMapController? _mapController;
  List<TripLocation> _selectedLocations = [];
  Set<Polyline> _routes = {};
  Set<Marker> _markers = {};
  final String _placesApiKey = 'AIzaSyD5fitoSIC-JDcKSTEOvnT0Yt-WF9NxvqQ';
  bool _showSearchResults = false;
  List<TextEditingController> _locationControllers = [TextEditingController()];
  List<FocusNode> _locationFocusNodes = [FocusNode()];
  int _activeSearchIndex = -1;
  Map<int, List<dynamic>> _searchResultsMap = {};
  final TripStateManager _tripStateManager = TripStateManager();
  bool _isMapExpanded = false;
  final MapCacheService _mapCache = MapCacheService();
  final TripPlanService _tripService = TripPlanService();
  String? _currentTripId;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final SessionManager _sessionManager = SessionManager();

  @override
  void initState() {
    super.initState();
    _currentTripId = widget.tripId;

    // Load the current trip first
    _loadCurrentTrip();

    _initializeMap();

    if (widget.initialPlace != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _addInitialPlace();
      });
    }
  }

  Future<void> _loadCurrentTrip() async {
    try {
      // If we have a specific tripId from widget, use that instead of querying for current trip
      if (widget.tripId != null && widget.savedLocations != null) {
        _currentTripId = widget.tripId;

        setState(() {
          // Clear existing controllers and nodes
          for (var controller in _locationControllers) {
            controller.dispose();
          }
          for (var node in _locationFocusNodes) {
            node.dispose();
          }

          _selectedLocations = List.from(widget.savedLocations!);

          // Update TripStateManager with loaded locations
          _tripStateManager.locations = List.from(_selectedLocations);

          // Initialize controllers and nodes
          _locationControllers = List.generate(
            _selectedLocations.isEmpty ? 1 : _selectedLocations.length + 1,
            (index) {
              var controller = TextEditingController();
              if (index < _selectedLocations.length) {
                controller.text = _selectedLocations[index].name;
              }
              return controller;
            },
          );

          _locationFocusNodes = List.generate(
            _locationControllers.length,
            (index) =>
                FocusNode()..addListener(() => _setupLocationInput(index)),
          );

          _updateMapMarkers();
          _updateRoutes();
        });

        // Update this trip to be the current trip
        await _updateTripStatus();
        return;
      }

      // Otherwise, try to get the current trip
      final querySnapshot = await _firestore
          .collection('trips')
          .where('userEmail', isEqualTo: widget.userEmail)
          .where('isCurrentTrip', isEqualTo: true)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        final currentTripDoc = querySnapshot.docs.first;
        _currentTripId = currentTripDoc.id;

        final data = currentTripDoc.data();
        final locations =
            List<Map<String, dynamic>>.from(data['locations'] ?? []);

        setState(() {
          // Clear existing controllers and nodes
          for (var controller in _locationControllers) {
            controller.dispose();
          }
          for (var node in _locationFocusNodes) {
            node.dispose();
          }

          _selectedLocations =
              locations.map((loc) => TripLocation.fromMap(loc)).toList();

          // Update TripStateManager with loaded locations
          _tripStateManager.locations = List.from(_selectedLocations);

          // Initialize controllers and nodes
          _locationControllers = List.generate(
            _selectedLocations.isEmpty ? 1 : _selectedLocations.length + 1,
            (index) {
              var controller = TextEditingController();
              if (index < _selectedLocations.length) {
                controller.text = _selectedLocations[index].name;
              }
              return controller;
            },
          );

          _locationFocusNodes = List.generate(
            _locationControllers.length,
            (index) =>
                FocusNode()..addListener(() => _setupLocationInput(index)),
          );

          _updateMapMarkers();
          _updateRoutes();
        });
      } else {
        // If no current trip is found, load saved locations
        _loadSavedLocations();
      }
    } catch (e) {
      print('Error loading current trip: $e');
      // Fallback to loading saved locations
      _loadSavedLocations();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only reload if we don't have a specific trip to restore
    if (mounted && widget.tripId == null) {
      _loadCurrentTrip();
    }
  }

  Future<void> _initializeMap() async {
    final initialPosition = await _mapCache.getInitialPosition();
    if (_mapController != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(initialPosition),
      );
    }

    // Restore cached markers
    setState(() {
      _markers = _mapCache.getCachedMarkers();
    });
  }

  void _setupLocationInput(int index) {
    if (index >= _locationFocusNodes.length) return;

    _locationFocusNodes[index].addListener(() {
      if (_locationFocusNodes[index].hasFocus) {
        setState(() {
          _activeSearchIndex = index;
          _showSearchResults = true;
        });
      }
    });
  }

  Future<void> _searchPlaces(String query, int fieldIndex) async {
    if (query.isEmpty) {
      setState(() {
        _searchResultsMap[fieldIndex] = [];
        _showSearchResults = false;
        _activeSearchIndex = -1;
      });
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('https://maps.googleapis.com/maps/api/place/autocomplete/json'
            '?input=${Uri.encodeComponent(query)}'
            '&key=$_placesApiKey'
            '&components=country:my'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _searchResultsMap[fieldIndex] = data['predictions'];
          _showSearchResults = data['predictions'].isNotEmpty;
          _activeSearchIndex = fieldIndex;
        });
      }
    } catch (e) {
      print('Error searching places: $e');
    }
  }

  Future<void> _selectPlace(String placeId, int index) async {
    try {
      final response = await http.get(
        Uri.parse('https://maps.googleapis.com/maps/api/place/details/json'
            '?place_id=$placeId'
            '&fields=name,geometry,formatted_address'
            '&key=$_placesApiKey'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final result = data['result'];

        final newLocation = TripLocation(
          placeId: placeId,
          name: result['name'],
          address: result['formatted_address'],
          latLng: LatLng(
            result['geometry']['location']['lat'],
            result['geometry']['location']['lng'],
          ),
        );

        // Get current trip ID first
        String? tripId =
            _currentTripId ?? await _sessionManager.getSessionTripId();

        if (tripId == null) {
          // Create a new trip if no current trip exists
          final newTripRef = await _firestore.collection('trips').add({
            'userEmail': widget.userEmail,
            'isCurrentTrip': true,
            'createdAt': FieldValue.serverTimestamp(),
            'locations': [],
          });
          tripId = newTripRef.id;
          _currentTripId = tripId;
          await _sessionManager.setSessionTripId(tripId);
        }

        setState(() {
          _showSearchResults = false;
          _activeSearchIndex = -1;

          // Add or update location
          if (index >= _selectedLocations.length) {
            _selectedLocations.add(newLocation);
            _tripStateManager.addLocation(newLocation);

            // Add a new empty field for the next location
            _locationControllers.add(TextEditingController());
            _locationFocusNodes.add(FocusNode());
            _setupLocationInput(_locationControllers.length - 1);
          } else {
            _selectedLocations[index] = newLocation;
            _tripStateManager.locations[index] = newLocation;
          }

          _updateMapMarkers();
          _updateRoutes();
        });

        // Update Firestore with the new location
        try {
          await _firestore.collection('trips').doc(tripId).set({
            'userEmail': widget.userEmail,
            'locations': _selectedLocations.map((loc) => loc.toMap()).toList(),
            'lastUpdated': FieldValue.serverTimestamp(),
            'isCurrentTrip': true,
          }, SetOptions(merge: true));
        } catch (dbError) {
          print('Database error: $dbError');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Failed to save location. Please check your internet connection and try again.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('Error getting place details: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding location. Please try again.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _deleteLocation(int index) async {
    if (_selectedLocations.isEmpty ||
        index < 0 ||
        index >= _selectedLocations.length) {
      return;
    }

    try {
      // Get current trip ID
      String? tripId =
          _currentTripId ?? await _sessionManager.getSessionTripId();
      if (tripId == null) return;

      // Remove the location from local state
      setState(() {
        _selectedLocations.removeAt(index);
        _tripStateManager.removeLocation(index);

        // Clean up controllers and focus nodes
        if (_locationControllers.length > index) {
          _locationControllers[index].dispose();
          _locationControllers.removeAt(index);
          _locationFocusNodes[index].dispose();
          _locationFocusNodes.removeAt(index);
        }

        // Update the text in the remaining controllers
        for (int i = index;
            i < _selectedLocations.length && i < _locationControllers.length;
            i++) {
          _locationControllers[i].text = _selectedLocations[i].name;
        }

        // Ensure there's always at least one empty input field
        if (_locationControllers.isEmpty) {
          _locationControllers.add(TextEditingController());
          _locationFocusNodes.add(FocusNode());
          _setupLocationInput(0);
        }

        // Update map and routes
        _updateMapMarkers();
        _updateRoutes();
      });

      // Update Firestore with the new locations list
      await _firestore.collection('trips').doc(tripId).update({
        'locations': _selectedLocations.map((loc) => loc.toMap()).toList(),
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating database after location removal: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed to update database after removing location')),
      );
    }
  }

  Future<void> _saveLocations() async {
    try {
      final tripId = widget.tripId ?? await _sessionManager.getSessionTripId();
      if (tripId != null) {
        // Get current locations from Firestore
        final tripDoc = await _firestore.collection('trips').doc(tripId).get();

        if (tripDoc.exists) {
          final data = tripDoc.data() as Map<String, dynamic>;
          final existingLocations =
              List<Map<String, dynamic>>.from(data['locations'] ?? []);

          // Create a set of existing place IDs to avoid duplicates
          final existingPlaceIds = Set<String>.from(
              existingLocations.map((loc) => loc['placeId'] as String));

          // Add only new locations that don't already exist
          for (var location in _selectedLocations) {
            if (!existingPlaceIds.contains(location.placeId)) {
              existingLocations.add(location.toMap());
              existingPlaceIds.add(location.placeId);
            }
          }

          // Update Firestore with merged locations
          await _firestore.collection('trips').doc(tripId).update({
            'locations': existingLocations,
            'lastUpdated': FieldValue.serverTimestamp(),
          });
        } else {
          // If no document exists, create new one with current locations
          await _firestore.collection('trips').doc(tripId).set({
            'locations': _selectedLocations.map((loc) => loc.toMap()).toList(),
            'lastUpdated': FieldValue.serverTimestamp(),
            'userEmail': widget.userEmail,
            'isCurrentTrip': true,
          });
        }
      }
    } catch (e) {
      print('Error saving locations: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save locations')),
      );
    }
  }

  void _handleTapOutside() {
    setState(() {
      _showSearchResults = false;
      _activeSearchIndex = -1;
    });
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mapController?.dispose();
    for (var controller in _locationControllers) {
      controller.dispose();
    }
    for (var node in _locationFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTapOutside,
      child: Scaffold(
        body: SafeArea(
          child: _isMapExpanded
              ? _buildExpandedMap()
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Text(
                          'My Trip',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _buildMapSection(),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Where do you want to go?',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            SizedBox(height: 8),
                            _buildSearchBar(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        bottomNavigationBar: !_isMapExpanded
            ? CustomBottomNav(
                currentIndex: 3,
                userEmail: widget.userEmail,
              )
            : null,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Location Input Row with Wrapping
          Wrap(
            spacing: 8, // gap between adjacent chips
            runSpacing: 8, // gap between lines
            children: [
              // Existing Locations
              ..._selectedLocations.map((location) {
                final index = _selectedLocations.indexOf(location);
                return Container(
                  height: 32,
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        location.name,
                        style: TextStyle(fontSize: 14),
                      ),
                      SizedBox(width: 4),
                      InkWell(
                        onTap: () => _deleteLocation(index),
                        child: Icon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                );
              }),

              // Input Field
              Container(
                height: 32,
                constraints: BoxConstraints(minWidth: 100),
                child: TextField(
                  controller: _locationControllers.last,
                  focusNode: _locationFocusNodes.last,
                  decoration: InputDecoration(
                    hintText: _selectedLocations.isEmpty
                        ? 'Enter countries, cities, or places to visit on your trip'
                        : 'And then to?',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: (value) {
                    if (value.trim().isEmpty) {
                      setState(() {
                        _searchResultsMap[_locationControllers.length - 1] = [];
                        _showSearchResults = false;
                      });
                    } else {
                      _searchPlaces(value, _locationControllers.length - 1);
                    }
                  },
                ),
              ),
            ],
          ),

          // Action Buttons
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_selectedLocations.isNotEmpty)
                  TextButton(
                    onPressed: () => _clearLocations(),
                    child: Text(
                      'Clear',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    if (_selectedLocations.length >= 2) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => _selectedLocations.length > 2
                              ? MultiTransportationRoutePage(
                                  locations: _selectedLocations,
                                  userEmail: widget.userEmail,
                                  onLocationRemoved: (location) {
                                    final index = _selectedLocations.indexWhere(
                                        (loc) =>
                                            loc.placeId == location.placeId);
                                    if (index != -1) {
                                      _deleteLocation(index);
                                    }
                                  },
                                  onLocationsUpdated: _syncLocations,
                                )
                              : TransportationRoutePage(
                                  locations: _selectedLocations,
                                  userEmail: widget.userEmail,
                                  onLocationRemoved: (location) {
                                    final index = _selectedLocations.indexWhere(
                                        (loc) =>
                                            loc.placeId == location.placeId);
                                    if (index != -1) {
                                      _deleteLocation(index);
                                    }
                                  },
                                  onLocationsUpdated: _syncLocations,
                                ),
                        ),
                      );
                    }
                  },
                  child: Text(
                    'Search',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: TextButton.styleFrom(
                    backgroundColor: _selectedLocations.length >= 2
                        ? Colors.blue
                        : Colors.grey,
                    minimumSize: Size(80, 36),
                    padding: EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ],
            ),
          ),

          // Search Results
          if (_showSearchResults &&
              _searchResultsMap[_activeSearchIndex]?.isNotEmpty == true)
            Container(
              margin: EdgeInsets.only(top: 8),
              constraints: BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResultsMap[_activeSearchIndex]?.length ?? 0,
                itemBuilder: (context, index) {
                  final place = _searchResultsMap[_activeSearchIndex]![index];
                  return ListTile(
                    dense: true,
                    title: Text(place['description']),
                    onTap: () {
                      _locationControllers[_activeSearchIndex].text =
                          place['description'];
                      _selectPlace(place['place_id'], _activeSearchIndex);
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMapSection() {
    return FutureBuilder<CameraPosition>(
      future: _mapCache.getInitialPosition(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Container(
            height: 200,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        return Stack(
          children: [
            Container(
              height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: GoogleMap(
                  initialCameraPosition: snapshot.data!,
                  onMapCreated: (controller) {
                    _mapController = controller;
                    _updateMapMarkers();
                  },
                  markers: _markers,
                  polylines: _routes,
                  mapType: MapType.normal,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  zoomGesturesEnabled: true,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: FloatingActionButton(
                mini: true,
                backgroundColor: Colors.white,
                child: Icon(Icons.fullscreen, color: Colors.black87),
                onPressed: () {
                  setState(() {
                    _isMapExpanded = true;
                  });
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildExpandedMap() {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: LatLng(4.2105, 101.9758),
            zoom: 6,
          ),
          onMapCreated: (controller) {
            _mapController = controller;
            _updateMapMarkers();
          },
          markers: _markers,
          polylines: _routes,
          mapType: MapType.normal,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
          zoomControlsEnabled: true,
          zoomGesturesEnabled: true,
        ),
        Positioned(
          top: 16,
          left: 16,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: Colors.white,
            child: Icon(Icons.close, color: Colors.black87),
            onPressed: () {
              setState(() {
                _isMapExpanded = false;
              });
            },
          ),
        ),
      ],
    );
  }

  void _updateMapMarkers() {
    if (_mapController == null) return;

    setState(() {
      _markers.clear();

      for (var i = 0; i < _selectedLocations.length; i++) {
        final location = _selectedLocations[i];
        _markers.add(
          Marker(
            markerId: MarkerId(location.placeId),
            position: location.latLng,
            infoWindow: InfoWindow(
              title: location.name,
              snippet: 'Stop ${i + 1}',
            ),
          ),
        );
      }

      // Adjust map view if there are markers
      if (_markers.isNotEmpty) {
        _fitMapBounds();

        // Cache the current map state
        _mapController!.getVisibleRegion().then((bounds) {
          final position = CameraPosition(
            target: LatLng(
              (bounds.northeast.latitude + bounds.southwest.latitude) / 2,
              (bounds.northeast.longitude + bounds.southwest.longitude) / 2,
            ),
            zoom: 15,
          );
          _mapCache.cacheMapState(position, _markers);
        });
      }
    });
  }

  void _fitMapBounds() {
    if (_markers.isEmpty || _mapController == null) return;

    // Calculate bounds with padding
    double minLat = double.infinity;
    double maxLat = -double.infinity;
    double minLng = double.infinity;
    double maxLng = -double.infinity;

    // Find the bounding box for all markers
    for (Marker marker in _markers) {
      final lat = marker.position.latitude;
      final lng = marker.position.longitude;
      minLat = min(minLat, lat);
      maxLat = max(maxLat, lat);
      minLng = min(minLng, lng);
      maxLng = max(maxLng, lng);
    }

    // Add padding to the bounds (about 15% on each side)
    final latPadding = (maxLat - minLat) * 0.15;
    final lngPadding = (maxLng - minLng) * 0.15;

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            minLat - latPadding,
            minLng - lngPadding,
          ),
          northeast: LatLng(
            maxLat + latPadding,
            maxLng + lngPadding,
          ),
        ),
        50, // padding in pixels
      ),
    );
  }

  void _updateRoutes() {
    // TODO: Implement route updating using Google Directions API
  }

  void _restoreLocations() {
    setState(() {
      _selectedLocations = List.from(_tripStateManager.locations);

      // Always ensure at least one empty field
      _locationControllers = List.generate(
        _selectedLocations.length + 1,
        (index) {
          var controller = TextEditingController();
          if (index < _selectedLocations.length) {
            controller.text = _selectedLocations[index].name;
          }
          return controller;
        },
      );

      _locationFocusNodes = List.generate(
        _locationControllers.length,
        (index) => FocusNode(),
      );

      for (var i = 0; i < _locationControllers.length; i++) {
        _setupLocationInput(i);
      }

      _updateMapMarkers();
      _updateRoutes();
    });
  }

  Future<void> _addInitialPlace() async {
    if (widget.initialPlace == null) return;

    final place = widget.initialPlace!;
    final placeId = place['place_id'];
    if (placeId == null) return;

    try {
      // Get current trip ID from Firestore
      final querySnapshot = await _firestore
          .collection('trips')
          .where('userEmail', isEqualTo: widget.userEmail)
          .where('isCurrentTrip', isEqualTo: true)
          .get();

      String? tripId;

      if (querySnapshot.docs.isNotEmpty) {
        // Use existing current trip
        tripId = querySnapshot.docs.first.id;
        _currentTripId = tripId;
      } else {
        // Create new trip only if no current trip exists
        final newTripRef = await _firestore.collection('trips').add({
          'userEmail': widget.userEmail,
          'isCurrentTrip': true,
          'createdAt': FieldValue.serverTimestamp(),
          'locations': [],
        });
        tripId = newTripRef.id;
        _currentTripId = tripId;
      }

      await _sessionManager.setSessionTripId(tripId);

      // Get place details
      final response = await http.get(
        Uri.parse('https://maps.googleapis.com/maps/api/place/details/json'
            '?place_id=$placeId'
            '&fields=name,geometry,formatted_address'
            '&key=$_placesApiKey'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['result'] == null) {
          throw Exception('No place details found');
        }

        final result = data['result'];
        final newLocation = TripLocation(
          placeId: placeId,
          name: result['name'] ?? 'Unknown Place',
          address: result['formatted_address'] ?? '',
          latLng: LatLng(
            result['geometry']?['location']?['lat'] ?? 0.0,
            result['geometry']?['location']?['lng'] ?? 0.0,
          ),
        );

        // Check if location already exists
        if (!_selectedLocations.any((loc) => loc.placeId == placeId)) {
          // Get current locations from Firestore
          final tripDoc =
              await _firestore.collection('trips').doc(tripId).get();
          final existingLocations = tripDoc.exists
              ? List<Map<String, dynamic>>.from(
                  tripDoc.data()?['locations'] ?? [])
              : [];

          // Add new location to existing locations
          existingLocations.add(newLocation.toMap());

          setState(() {
            _selectedLocations = existingLocations
                .map((loc) => TripLocation.fromMap(loc))
                .toList();
            _tripStateManager.locations = List.from(_selectedLocations);
            _updateLocationControllers();
            _updateMapMarkers();
            _updateRoutes();
          });

          // Move the Firestore update outside setState
          await _firestore.collection('trips').doc(tripId).update({
            'locations': existingLocations,
            'lastUpdated': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (e) {
      print('Error adding initial place: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adding location: $e')),
      );
    }
  }

  void _updateLocationControllers() {
    // Dispose existing controllers
    for (var controller in _locationControllers) {
      controller.dispose();
    }

    // Create new controllers
    _locationControllers = List.generate(
      (_selectedLocations.isEmpty ? 1 : _selectedLocations.length + 1),
      (index) {
        var controller = TextEditingController();
        if (index < _selectedLocations.length) {
          controller.text = _selectedLocations[index].name;
        }
        return controller;
      },
    );

    // Update focus nodes
    for (var node in _locationFocusNodes) {
      node.dispose();
    }
    _locationFocusNodes = List.generate(
      _locationControllers.length,
      (index) => FocusNode()..addListener(() => _setupLocationInput(index)),
    );
  }

  Future<void> _addLocation(TripLocation location) async {
    setState(() {
      _selectedLocations.add(location);
      _updateLocationControllers();
      _updateMapMarkers();
      _updateRoutes();
    });

    try {
      final tripId = _currentTripId ?? _sessionManager.sessionTripId;
      if (tripId != null) {
        await _tripService.updateLocations(_selectedLocations);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save location: $e')),
      );
    }
  }

  Future<void> _loadSavedLocations() async {
    try {
      final tripId = widget.tripId ?? await _sessionManager.getSessionTripId();

      if (tripId != null) {
        final tripDoc = await _firestore.collection('trips').doc(tripId).get();

        if (tripDoc.exists) {
          final data = tripDoc.data() as Map<String, dynamic>;
          final locations =
              List<Map<String, dynamic>>.from(data['locations'] ?? []);

          setState(() {
            // Clear existing controllers and nodes
            for (var controller in _locationControllers) {
              controller.dispose();
            }
            for (var node in _locationFocusNodes) {
              node.dispose();
            }

            _selectedLocations =
                locations.map((loc) => TripLocation.fromMap(loc)).toList();

            // Update TripStateManager with loaded locations
            _tripStateManager.locations = List.from(_selectedLocations);

            // Initialize controllers and nodes
            _locationControllers = List.generate(
              _selectedLocations.isEmpty ? 1 : _selectedLocations.length + 1,
              (index) {
                var controller = TextEditingController();
                if (index < _selectedLocations.length) {
                  controller.text = _selectedLocations[index].name;
                }
                return controller;
              },
            );

            _locationFocusNodes = List.generate(
              _locationControllers.length,
              (index) =>
                  FocusNode()..addListener(() => _setupLocationInput(index)),
            );

            _updateMapMarkers();
            _updateRoutes();
          });
        }
      }
    } catch (e) {
      print('Error loading saved locations: $e');
      // Initialize with empty state if loading fails
      setState(() {
        _selectedLocations = [];
        _tripStateManager.locations = []; // Clear TripStateManager as well
        _locationControllers = [TextEditingController()];
        _locationFocusNodes = [FocusNode()];
        _setupLocationInput(0);
        _markers.clear();
        _routes.clear();
      });
    }
  }

  void _clearLocations() async {
    try {
      String? tripId =
          _currentTripId ?? await _sessionManager.getSessionTripId();
      if (tripId == null) return;

      // Clear UI state first
      setState(() {
        _selectedLocations.clear();
        _tripStateManager.locations.clear();
        _searchResultsMap.clear();
        _showSearchResults = false;
        _activeSearchIndex = -1;

        // Dispose old controllers and nodes
        for (var controller in _locationControllers) {
          controller.dispose();
        }
        for (var node in _locationFocusNodes) {
          node.dispose();
        }

        // Initialize with one empty controller and focus node
        _locationControllers = [TextEditingController()];
        _locationFocusNodes = [FocusNode()];

        // Clear map markers and routes
        _markers.clear();
        _routes.clear();
      });

      // Set up the input field after state is cleared
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _setupLocationInput(0);
        // Request focus after a short delay to ensure the widget is built
        Future.delayed(Duration(milliseconds: 100), () {
          if (_locationFocusNodes.isNotEmpty && mounted) {
            _locationFocusNodes[0].requestFocus();
          }
        });
      });

      // Update Firestore
      await _firestore.collection('trips').doc(tripId).update({
        'locations': [],
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error clearing locations: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to clear locations')),
      );
    }
  }

  Future<void> _updateTripStatus() async {
    try {
      // First, get all current trips
      final currentTrips = await _firestore
          .collection('trips')
          .where('userEmail', isEqualTo: widget.userEmail)
          .where('isCurrentTrip', isEqualTo: true)
          .get();

      // Create a batch to update all in one transaction
      final batch = _firestore.batch();

      // Mark all trips as not current
      for (var doc in currentTrips.docs) {
        if (doc.id != _currentTripId) {
          batch.update(doc.reference, {'isCurrentTrip': false});
        }
      }

      // Mark this trip as current
      if (_currentTripId != null) {
        batch.update(_firestore.collection('trips').doc(_currentTripId),
            {'isCurrentTrip': true});
      }

      // Commit the batch
      await batch.commit();
    } catch (e) {
      print('Error updating trip status: $e');
    }
  }

  Future<void> _syncLocations(List<TripLocation> locations) async {
    try {
      String? tripId =
          _currentTripId ?? await _sessionManager.getSessionTripId();
      if (tripId == null) return;

      // Update local state
      setState(() {
        _selectedLocations = List.from(locations);
        _tripStateManager.locations = List.from(locations);

        // Update controllers and focus nodes
        for (var controller in _locationControllers) {
          controller.dispose();
        }
        for (var node in _locationFocusNodes) {
          node.dispose();
        }

        _locationControllers = List.generate(
          locations.isEmpty ? 1 : locations.length + 1,
          (index) {
            var controller = TextEditingController();
            if (index < locations.length) {
              controller.text = locations[index].name;
            }
            return controller;
          },
        );

        _locationFocusNodes = List.generate(
          _locationControllers.length,
          (index) => FocusNode()..addListener(() => _setupLocationInput(index)),
        );

        _updateMapMarkers();
        _updateRoutes();
      });

      // Update database
      await _firestore.collection('trips').doc(tripId).update({
        'locations': locations.map((loc) => loc.toMap()).toList(),
        'lastUpdated': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error syncing locations: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to sync locations')),
      );
    }
  }
}
